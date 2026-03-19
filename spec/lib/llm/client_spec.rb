# frozen_string_literal: true

require "rails_helper"

RSpec.describe LLM::Client do
  let(:fake_token) { "sk-ant-oat01-#{"a" * 68}" }
  let(:real_token) { CredentialStore.read("anthropic", "subscription_token") || fake_token }
  let(:provider) { Providers::Anthropic.new(real_token) }
  let(:client) { described_class.new(provider: provider) }

  describe "defaults from Settings" do
    it "uses Settings.model as default" do
      expect(client.model).to eq(Anima::Settings.model)
    end

    it "uses Settings.max_tokens as default" do
      expect(client.max_tokens).to eq(Anima::Settings.max_tokens)
    end
  end

  describe "#initialize" do
    it "accepts a custom provider" do
      client = described_class.new(provider: provider)
      expect(client.provider).to eq(provider)
    end

    it "creates a default provider when none given" do
      allow(Rails.application.credentials).to receive(:dig)
        .with(:anthropic, :subscription_token)
        .and_return(fake_token)

      client = described_class.new
      expect(client.provider).to be_a(Providers::Anthropic)
    end

    it "uses the default model" do
      expect(client.model).to eq("claude-sonnet-4-20250514")
    end

    it "uses the default max_tokens" do
      expect(client.max_tokens).to eq(8192)
    end

    it "accepts a custom model" do
      client = described_class.new(model: "claude-haiku-4-5-20251001", provider: provider)
      expect(client.model).to eq("claude-haiku-4-5-20251001")
    end

    it "accepts custom max_tokens" do
      client = described_class.new(max_tokens: 4096, provider: provider)
      expect(client.max_tokens).to eq(4096)
    end
  end

  describe "#chat" do
    it "returns the assistant's response text", :vcr do
      result = client.chat([{role: "user", content: "Reply with the single word OK"}])
      expect(result).to be_a(String)
      expect(result).to be_present
    end

    it "passes system prompt and options through to the provider", :vcr do
      result = client.chat(
        [{role: "user", content: "Reply with the single word OK"}],
        system: "You are helpful",
        temperature: 0.0
      )
      expect(result).to be_present
    end

    it "supports multi-turn conversations", :vcr do
      multi_turn = [
        {role: "user", content: "Remember the number 42"},
        {role: "assistant", content: "Got it, I'll remember 42."},
        {role: "user", content: "What number did I just say?"}
      ]

      result = client.chat(multi_turn)
      expect(result).to include("42")
    end

    it "uses the configured model", :vcr do
      haiku_client = described_class.new(
        model: "claude-haiku-4-5-20251001",
        provider: provider
      )

      result = haiku_client.chat([{role: "user", content: "Reply with the single word OK"}])
      expect(result).to be_present
    end

    context "when the API returns an error", :vcr do
      let(:bad_provider) { Providers::Anthropic.new(fake_token) }
      let(:bad_client) { described_class.new(provider: bad_provider) }

      it "propagates authentication errors" do
        expect {
          bad_client.chat([{role: "user", content: "Hi"}])
        }.to raise_error(Providers::Anthropic::AuthenticationError)
      end
    end
  end

  describe "#chat_with_tools" do
    let(:session) { Session.create! }
    let(:registry) { Tools::Registry.new }

    let(:tool_class) do
      Class.new(Tools::Base) do
        def self.tool_name = "web_get"
        def self.description = "Fetch a URL and return its contents"

        def self.input_schema
          {type: "object", properties: {url: {type: "string"}}, required: ["url"]}
        end

        def execute(input)
          "<html>Example Domain</html>"
        end
      end
    end

    before { registry.register(tool_class) }

    context "when the LLM responds without tool use", :vcr do
      it "returns the text response directly" do
        result = client.chat_with_tools(
          [{role: "user", content: "What is 2 + 2? Just answer the number."}],
          registry: registry, session_id: session.id
        )
        expect(result).to be_present
      end
    end

    context "when the LLM calls a tool", :vcr do
      let(:messages) { [{role: "user", content: "Use the web_get tool to fetch https://example.com and tell me what you find"}] }

      it "executes the tool and returns the final response" do
        result = client.chat_with_tools(messages, registry: registry, session_id: session.id)
        expect(result).to be_present
      end

      it "emits ToolCall and ToolResponse events" do
        events = []
        subscriber = spy("sub")
        allow(subscriber).to receive(:emit) { |e| events << e }
        Events::Bus.subscribe(subscriber)

        client.chat_with_tools(messages, registry: registry, session_id: session.id)

        tool_call = events.find { |e| e[:payload][:type] == "tool_call" }
        expect(tool_call[:payload][:tool_name]).to eq("web_get")

        tool_response = events.find { |e| e[:payload][:type] == "tool_response" }
        expect(tool_response[:payload][:tool_name]).to eq("web_get")
        expect(tool_response[:payload][:success]).to be true
      ensure
        Events::Bus.unsubscribe(subscriber)
      end
    end

    context "when the tool returns an error", :vcr do
      let(:failing_tool_class) do
        Class.new(Tools::Base) do
          def self.tool_name = "web_get"
          def self.description = "Fetch a URL and return its contents"
          def self.input_schema = {type: "object", properties: {url: {type: "string"}}, required: ["url"]}

          def execute(_input)
            {error: "Connection refused"}
          end
        end
      end

      let(:error_registry) do
        r = Tools::Registry.new
        r.register(failing_tool_class)
        r
      end

      it "emits ToolResponse with success: false" do
        events = []
        subscriber = spy("sub")
        allow(subscriber).to receive(:emit) { |e| events << e }
        Events::Bus.subscribe(subscriber)

        client.chat_with_tools(
          [{role: "user", content: "Use the web_get tool to fetch https://example.com"}],
          registry: error_registry, session_id: session.id
        )

        tool_response = events.find { |e| e[:payload][:type] == "tool_response" }
        expect(tool_response[:payload][:success]).to be false
      ensure
        Events::Bus.unsubscribe(subscriber)
      end
    end

    context "when the tool raises an unexpected exception", :vcr do
      let(:exploding_tool_class) do
        Class.new(Tools::Base) do
          def self.tool_name = "web_get"
          def self.description = "Fetch a URL and return its contents"
          def self.input_schema = {type: "object", properties: {url: {type: "string"}}, required: ["url"]}

          def execute(_input)
            raise "something went terribly wrong"
          end
        end
      end

      let(:exploding_registry) do
        r = Tools::Registry.new
        r.register(exploding_tool_class)
        r
      end

      it "catches the exception and emits ToolResponse with success: false" do
        events = []
        subscriber = spy("sub")
        allow(subscriber).to receive(:emit) { |e| events << e }
        Events::Bus.subscribe(subscriber)

        result = client.chat_with_tools(
          [{role: "user", content: "Use the web_get tool to fetch https://example.com"}],
          registry: exploding_registry, session_id: session.id
        )

        expect(result).to be_present
        tool_response = events.find { |e| e[:payload][:type] == "tool_response" }
        expect(tool_response[:payload][:success]).to be false
        expect(tool_response[:payload][:content]).to include("RuntimeError")
        expect(tool_response[:payload][:content]).to include("something went terribly wrong")
      ensure
        Events::Bus.unsubscribe(subscriber)
      end
    end

    context "when the user interrupts during tool execution", :vcr do
      let(:messages) { [{role: "user", content: "Use the web_get tool to fetch https://example.com"}] }

      it "returns nil when interrupted before tools execute" do
        session.update_column(:interrupt_requested, true)

        result = client.chat_with_tools(messages, registry: registry, session_id: session.id)
        expect(result).to be_nil
      end

      it "creates synthetic 'Stopped by user' tool_results" do
        session.update_column(:interrupt_requested, true)

        events = []
        subscriber = spy("sub")
        allow(subscriber).to receive(:emit) { |e| events << e }
        Events::Bus.subscribe(subscriber)

        client.chat_with_tools(messages, registry: registry, session_id: session.id)

        tool_responses = events.select { |e| e[:payload][:type] == "tool_response" }
        expect(tool_responses).not_to be_empty
        tool_responses.each do |resp|
          expect(resp[:payload][:content]).to eq(LLM::Client::INTERRUPT_MESSAGE)
          expect(resp[:payload][:success]).to be false
        end
      ensure
        Events::Bus.unsubscribe(subscriber)
      end

      it "clears the interrupt flag" do
        session.update_column(:interrupt_requested, true)

        client.chat_with_tools(messages, registry: registry, session_id: session.id)

        expect(session.reload.interrupt_requested?).to be false
      end

      it "executes first tool then interrupts remaining when flag arrives mid-execution", :vcr do
        # Use two tool calls so first executes, second gets interrupted
        two_url_messages = [{role: "user", content: "Use the web_get tool to fetch both https://example.com and https://example.org"}]
        sid = session.id
        tool_class.define_method(:execute) do |_input|
          Session.where(id: sid).update_all(interrupt_requested: true)
          "first result"
        end

        events = []
        subscriber = spy("sub")
        allow(subscriber).to receive(:emit) { |e| events << e }
        Events::Bus.subscribe(subscriber)

        client.chat_with_tools(two_url_messages, registry: registry, session_id: session.id)

        tool_responses = events.select { |e| e[:payload][:type] == "tool_response" }
        expect(tool_responses.size).to eq(2)
        expect(tool_responses[0][:payload][:content]).to eq("first result")
        expect(tool_responses[0][:payload][:success]).to be true
        expect(tool_responses[1][:payload][:content]).to eq(LLM::Client::INTERRUPT_MESSAGE)
        expect(tool_responses[1][:payload][:success]).to be false
      ensure
        Events::Bus.unsubscribe(subscriber)
      end
    end

    context "when the tool loop exceeds max_tool_rounds" do
      it "halts and returns an error message" do
        VCR.use_cassette("llm_client/tool_loop_forever",
          allow_playback_repeats: true,
          match_requests_on: [:method, :uri],
          record: :none) do
          result = client.chat_with_tools(
            [{role: "user", content: "Use web_get to fetch https://example.com"}],
            registry: registry, session_id: session.id
          )
          expect(result).to include("Tool loop exceeded")
        end
      end
    end
  end
end
