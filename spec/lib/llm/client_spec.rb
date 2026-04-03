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
      Secret.write("anthropic", "subscription_token" => fake_token)

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

  describe "#chat_with_tools" do
    let(:session) { Session.create! }
    let(:registry) { Tools::Registry.new }
    let(:llm_options) { {system: "You are Anima"} }

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
      it "returns a Hash with :text and :api_metrics keys" do
        result = client.chat_with_tools(
          [{role: "user", content: "What is 2 + 2? Just answer the number."}],
          registry: registry, session_id: session.id, **llm_options
        )
        expect(result).to be_a(Hash)
        expect(result[:text]).to be_a(String)
        expect(result).to have_key(:api_metrics)
      end
    end

    context "when the LLM calls a tool", :vcr do
      let(:messages) { [{role: "user", content: "Use the web_get tool to fetch https://example.com and tell me what you find"}] }

      it "executes the tool and returns a Hash with :text and :api_metrics keys" do
        result = client.chat_with_tools(messages, registry: registry, session_id: session.id, **llm_options)
        expect(result).to be_a(Hash)
        expect(result[:text]).to be_present
        expect(result).to have_key(:api_metrics)
      end

      it "emits ToolCall and ToolResponse events" do
        events = []
        subscriber = spy("sub")
        allow(subscriber).to receive(:emit) { |e| events << e }
        Events::Bus.subscribe(subscriber)

        client.chat_with_tools(messages, registry: registry, session_id: session.id, **llm_options)

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
          registry: error_registry, session_id: session.id, **llm_options
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
          registry: exploding_registry, session_id: session.id, **llm_options
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

        result = client.chat_with_tools(messages, registry: registry, session_id: session.id, **llm_options)
        expect(result).to be_nil
      end

      it "creates synthetic 'Your human wants your attention' tool_results" do
        session.update_column(:interrupt_requested, true)

        events = []
        subscriber = spy("sub")
        allow(subscriber).to receive(:emit) { |e| events << e }
        Events::Bus.subscribe(subscriber)

        client.chat_with_tools(messages, registry: registry, session_id: session.id, **llm_options)

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

        client.chat_with_tools(messages, registry: registry, session_id: session.id, **llm_options)

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

        client.chat_with_tools(two_url_messages, registry: registry, session_id: session.id, **llm_options)

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

    context "when the user interrupts during text generation", :vcr do
      it "discards the text response and returns nil" do
        messages = [{role: "user", content: "Reply with the single word OK"}]
        session.update_column(:interrupt_requested, true)

        result = client.chat_with_tools(
          messages,
          registry: registry, session_id: session.id, **llm_options
        )

        expect(result).to be_nil
        expect(session.reload.interrupt_requested?).to be false
      end
    end

    context "when post-execution code raises", :vcr do
      let(:messages) { [{role: "user", content: "Use the web_get tool to fetch https://example.com"}] }

      it "still produces a tool_result and emits ToolResponse" do
        allow(ToolDecorator).to receive(:call).and_raise(
          Encoding::CompatibilityError, "incompatible character encodings: ASCII-8BIT and UTF-8"
        )

        events = []
        subscriber = spy("sub")
        allow(subscriber).to receive(:emit) { |e| events << e }
        Events::Bus.subscribe(subscriber)

        result = client.chat_with_tools(messages, registry: registry, session_id: session.id, **llm_options)

        expect(result).to be_present
        tool_response = events.find { |e| e[:payload][:type] == "tool_response" }
        expect(tool_response).to be_present
        expect(tool_response[:payload][:tool_name]).to eq("web_get")
        expect(tool_response[:payload][:tool_use_id]).to be_present
        expect(tool_response[:payload][:success]).to be false
        expect(tool_response[:payload][:content]).to include("Encoding::CompatibilityError")
        expect(tool_response[:payload][:content]).to include("incompatible character encodings")
      ensure
        Events::Bus.unsubscribe(subscriber)
      end
    end

    context "when Anthropic returns nil tool_use id" do
      it "generates a fallback UUID for execute_single_tool" do
        events = []
        subscriber = spy("sub")
        allow(subscriber).to receive(:emit) { |e| events << e }
        Events::Bus.subscribe(subscriber)

        tool_use = {"name" => "web_get", "id" => nil, "input" => {"url" => "https://example.com"}}
        result = client.send(:execute_single_tool, tool_use, registry, session.id)

        expect(result[:tool_use_id]).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)

        tool_call = events.find { |e| e[:payload][:type] == "tool_call" }
        tool_response = events.find { |e| e[:payload][:type] == "tool_response" }
        expect(tool_call[:payload][:tool_use_id]).to eq(result[:tool_use_id])
        expect(tool_response[:payload][:tool_use_id]).to eq(result[:tool_use_id])
      ensure
        Events::Bus.unsubscribe(subscriber)
      end

      it "generates a fallback UUID for interrupt_tool" do
        events = []
        subscriber = spy("sub")
        allow(subscriber).to receive(:emit) { |e| events << e }
        Events::Bus.subscribe(subscriber)

        tool_use = {"name" => "web_get", "id" => nil, "input" => {}}
        result = client.send(:interrupt_tool, tool_use, session.id)

        expect(result[:tool_use_id]).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)

        tool_call = events.find { |e| e[:payload][:type] == "tool_call" }
        tool_response = events.find { |e| e[:payload][:type] == "tool_response" }
        expect(tool_call[:payload][:tool_use_id]).to eq(result[:tool_use_id])
        expect(tool_response[:payload][:tool_use_id]).to eq(result[:tool_use_id])
      ensure
        Events::Bus.unsubscribe(subscriber)
      end
    end

    context "with between_rounds callback" do
      let(:tool_use_response) do
        {
          "stop_reason" => "tool_use",
          "content" => [
            {"type" => "text", "text" => "Let me fetch that."},
            {"type" => "tool_use", "id" => "toolu_A", "name" => "web_get", "input" => {"url" => "https://example.com"}}
          ]
        }
      end

      let(:text_response) do
        {"stop_reason" => "end_turn", "content" => [{"type" => "text", "text" => "Here is the result."}]}
      end

      it "injects user text promotions as text blocks in tool_results" do
        call_count = 0
        captured_messages = nil
        between_rounds = -> { {texts: ["User typed something"], pairs: []} }

        allow(provider).to receive(:create_message) do |**kwargs|
          captured_messages = kwargs[:messages]
          call_count += 1
          (call_count == 1) ? tool_use_response : text_response
        end

        client.chat_with_tools(
          [{role: "user", content: "Fetch example.com"}],
          registry: registry, session_id: session.id, **llm_options,
          between_rounds: between_rounds
        )

        user_msg = captured_messages.find { |m| m[:role] == "user" && m[:content].is_a?(Array) }
        text_blocks = user_msg[:content].select { |b| b[:type] == "text" }
        expect(text_blocks.map { |b| b[:text] }).to eq(["User typed something"])
      end

      it "appends sub-agent pairs as separate conversation turns" do
        call_count = 0
        captured_messages = nil
        subagent_pair = [
          {role: "assistant", content: [{type: "tool_use", id: "subagent_msg_1", name: "subagent_message", input: {from: "sleuth"}}]},
          {role: "user", content: [{type: "tool_result", tool_use_id: "subagent_msg_1", content: "Found the bug"}]}
        ]
        between_rounds = -> { {texts: [], pairs: subagent_pair} }

        allow(provider).to receive(:create_message) do |**kwargs|
          captured_messages = kwargs[:messages]
          call_count += 1
          (call_count == 1) ? tool_use_response : text_response
        end

        client.chat_with_tools(
          [{role: "user", content: "Fetch example.com"}],
          registry: registry, session_id: session.id, **llm_options,
          between_rounds: between_rounds
        )

        # Sub-agent pair should appear after the tool_results message
        last_two = captured_messages.last(2)
        expect(last_two[0][:role]).to eq("assistant")
        expect(last_two[0][:content].first[:name]).to eq("subagent_message")
        expect(last_two[1][:role]).to eq("user")
        expect(last_two[1][:content].first[:content]).to eq("Found the bug")
      end

      it "does not inject anything when callback returns empty arrays" do
        call_count = 0
        captured_messages = nil
        allow(provider).to receive(:create_message) do |**kwargs|
          call_count += 1
          captured_messages = kwargs[:messages] if call_count == 2
          (call_count == 1) ? tool_use_response : text_response
        end

        client.chat_with_tools(
          [{role: "user", content: "Fetch example.com"}],
          registry: registry, session_id: session.id, **llm_options,
          between_rounds: -> { {texts: [], pairs: []} }
        )

        user_msg = captured_messages.last
        text_blocks = user_msg[:content].select { |b| b[:type] == "text" }
        tool_result_blocks = user_msg[:content].select { |b| b[:type] == "tool_result" }
        expect(text_blocks).to be_empty
        expect(tool_result_blocks).not_to be_empty
      end

      it "skips callback when between_rounds is nil" do
        call_count = 0
        allow(provider).to receive(:create_message) do |**_kwargs|
          call_count += 1
          (call_count == 1) ? tool_use_response : text_response
        end

        expect {
          client.chat_with_tools(
            [{role: "user", content: "Fetch example.com"}],
            registry: registry, session_id: session.id, **llm_options,
            between_rounds: nil
          )
        }.not_to raise_error
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
            registry: registry, session_id: session.id, **llm_options
          )
          expect(result[:text]).to include("Tool loop exceeded")
        end
      end
    end
  end
end
