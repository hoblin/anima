# frozen_string_literal: true

require "rails_helper"

RSpec.describe LLM::Client do
  let(:valid_token) { "sk-ant-oat01-#{"a" * 68}" }
  let(:provider) { Providers::Anthropic.new(valid_token) }
  let(:client) { described_class.new(provider: provider) }

  let(:api_response) do
    {
      id: "msg_123",
      type: "message",
      role: "assistant",
      content: [{type: "text", text: "Hello! How can I help you today?"}],
      model: "claude-sonnet-4-20250514",
      stop_reason: "end_turn",
      usage: {input_tokens: 10, output_tokens: 12}
    }
  end

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
        .and_return(valid_token)

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
    let(:messages) { [{role: "user", content: "Say hello"}] }

    before do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(
          status: 200,
          body: api_response.to_json,
          headers: {"content-type" => "application/json"}
        )
    end

    it "returns the assistant's response text" do
      result = client.chat(messages)
      expect(result).to eq("Hello! How can I help you today?")
    end

    it "sends messages to the provider with default parameters" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .with(
          body: {
            model: "claude-sonnet-4-20250514",
            messages: [{role: "user", content: "Say hello"}],
            max_tokens: 8192
          }.to_json
        )
        .to_return(
          status: 200,
          body: api_response.to_json,
          headers: {"content-type" => "application/json"}
        )

      client.chat(messages)
    end

    it "passes additional options through to the provider" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .with(
          body: hash_including("system" => "You are helpful", "temperature" => 0.7)
        )
        .to_return(
          status: 200,
          body: api_response.to_json,
          headers: {"content-type" => "application/json"}
        )

      client.chat(messages, system: "You are helpful", temperature: 0.7)
    end

    it "supports multi-turn conversations" do
      multi_turn = [
        {role: "user", content: "Hello"},
        {role: "assistant", content: "Hi there!"},
        {role: "user", content: "How are you?"}
      ]

      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .with(body: hash_including("messages" => multi_turn))
        .to_return(
          status: 200,
          body: api_response.to_json,
          headers: {"content-type" => "application/json"}
        )

      result = client.chat(multi_turn)
      expect(result).to eq("Hello! How can I help you today?")
    end

    it "uses the configured model" do
      custom_client = described_class.new(
        model: "claude-haiku-4-5-20251001",
        provider: provider
      )

      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .with(body: hash_including("model" => "claude-haiku-4-5-20251001"))
        .to_return(
          status: 200,
          body: api_response.to_json,
          headers: {"content-type" => "application/json"}
        )

      custom_client.chat(messages)
    end

    it "uses the configured max_tokens" do
      custom_client = described_class.new(
        max_tokens: 4096,
        provider: provider
      )

      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .with(body: hash_including("max_tokens" => 4096))
        .to_return(
          status: 200,
          body: api_response.to_json,
          headers: {"content-type" => "application/json"}
        )

      custom_client.chat(messages)
    end

    context "when response has multiple text blocks" do
      it "concatenates all text blocks" do
        multi_block_response = api_response.merge(
          content: [
            {type: "text", text: "First part. "},
            {type: "text", text: "Second part."}
          ]
        )

        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_return(
            status: 200,
            body: multi_block_response.to_json,
            headers: {"content-type" => "application/json"}
          )

        result = client.chat(messages)
        expect(result).to eq("First part. Second part.")
      end
    end

    context "when response has no content" do
      it "returns an empty string for nil content" do
        empty_response = api_response.merge(content: nil)

        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_return(
            status: 200,
            body: empty_response.to_json,
            headers: {"content-type" => "application/json"}
          )

        result = client.chat(messages)
        expect(result).to eq("")
      end

      it "returns an empty string for empty content array" do
        empty_response = api_response.merge(content: [])

        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_return(
            status: 200,
            body: empty_response.to_json,
            headers: {"content-type" => "application/json"}
          )

        result = client.chat(messages)
        expect(result).to eq("")
      end
    end

    context "when response contains non-text content blocks" do
      it "extracts only text blocks" do
        mixed_response = api_response.merge(
          content: [
            {type: "text", text: "Here is the result:"},
            {type: "tool_use", id: "tool_1", name: "calculator", input: {expr: "2+2"}}
          ]
        )

        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_return(
            status: 200,
            body: mixed_response.to_json,
            headers: {"content-type" => "application/json"}
          )

        result = client.chat(messages)
        expect(result).to eq("Here is the result:")
      end
    end

    context "when the API returns an error" do
      it "propagates provider errors" do
        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_return(
            status: 400,
            body: {error: {message: "invalid request"}}.to_json,
            headers: {"content-type" => "application/json"}
          )

        expect {
          client.chat(messages)
        }.to raise_error(Providers::Anthropic::Error, /Bad request/)
      end

      it "propagates authentication errors" do
        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_return(
            status: 401,
            body: {error: {message: "invalid token"}}.to_json,
            headers: {"content-type" => "application/json"}
          )

        expect {
          client.chat(messages)
        }.to raise_error(Providers::Anthropic::AuthenticationError)
      end

      it "propagates rate limit errors" do
        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_return(
            status: 429,
            body: {error: {message: "rate limited"}}.to_json,
            headers: {"content-type" => "application/json"}
          )

        expect {
          client.chat(messages)
        }.to raise_error(Providers::Anthropic::Error, /Rate limit/)
      end
    end
  end

  describe "#chat_with_tools" do
    let(:messages) { [{role: "user", content: "What is on example.com?"}] }
    let(:session) { Session.create! }
    let(:registry) { Tools::Registry.new }

    let(:tool_class) do
      Class.new(Tools::Base) do
        def self.tool_name = "web_get"
        def self.description = "Fetch URL"

        def self.input_schema
          {type: "object", properties: {url: {type: "string"}}, required: ["url"]}
        end

        def execute(input)
          "<html>Example Domain</html>"
        end
      end
    end

    before { registry.register(tool_class) }

    context "when the LLM responds with end_turn (no tool use)" do
      before do
        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_return(
            status: 200,
            body: api_response.to_json,
            headers: {"content-type" => "application/json"}
          )
      end

      it "returns the text response directly" do
        result = client.chat_with_tools(messages, registry: registry, session_id: session.id)
        expect(result).to eq("Hello! How can I help you today?")
      end

      it "sends tool schemas in the request" do
        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .with(body: hash_including("tools" => [hash_including("name" => "web_get")]))
          .to_return(
            status: 200,
            body: api_response.to_json,
            headers: {"content-type" => "application/json"}
          )

        client.chat_with_tools(messages, registry: registry, session_id: session.id)
      end
    end

    context "when the LLM requests a tool call" do
      let(:tool_use_response) do
        {
          id: "msg_tool",
          type: "message",
          role: "assistant",
          content: [
            {type: "tool_use", id: "toolu_abc123", name: "web_get", input: {url: "https://example.com"}}
          ],
          model: "claude-sonnet-4-20250514",
          stop_reason: "tool_use",
          usage: {input_tokens: 20, output_tokens: 30}
        }
      end

      let(:final_response) do
        {
          id: "msg_final",
          type: "message",
          role: "assistant",
          content: [{type: "text", text: "The page contains Example Domain."}],
          model: "claude-sonnet-4-20250514",
          stop_reason: "end_turn",
          usage: {input_tokens: 50, output_tokens: 20}
        }
      end

      before do
        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_return(
            {status: 200, body: tool_use_response.to_json, headers: {"content-type" => "application/json"}},
            {status: 200, body: final_response.to_json, headers: {"content-type" => "application/json"}}
          )
      end

      it "executes the tool and returns the final response" do
        result = client.chat_with_tools(messages, registry: registry, session_id: session.id)
        expect(result).to eq("The page contains Example Domain.")
      end

      it "emits a ToolCall event" do
        events = []
        subscriber = double("sub")
        allow(subscriber).to receive(:emit) { |e| events << e }
        Events::Bus.subscribe(subscriber)

        client.chat_with_tools(messages, registry: registry, session_id: session.id)

        tool_call_event = events.find { |e| e[:payload][:type] == "tool_call" }
        expect(tool_call_event[:payload]).to include(
          tool_name: "web_get",
          tool_use_id: "toolu_abc123"
        )
      ensure
        Events::Bus.unsubscribe(subscriber)
      end

      it "emits a ToolResponse event" do
        events = []
        subscriber = double("sub")
        allow(subscriber).to receive(:emit) { |e| events << e }
        Events::Bus.subscribe(subscriber)

        client.chat_with_tools(messages, registry: registry, session_id: session.id)

        tool_response_event = events.find { |e| e[:payload][:type] == "tool_response" }
        expect(tool_response_event[:payload]).to include(
          tool_name: "web_get",
          tool_use_id: "toolu_abc123",
          success: true,
          content: "<html>Example Domain</html>"
        )
      ensure
        Events::Bus.unsubscribe(subscriber)
      end

      it "sends tool results back to the LLM" do
        requests = []
        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_return(
            {status: 200, body: tool_use_response.to_json, headers: {"content-type" => "application/json"}},
            {status: 200, body: final_response.to_json, headers: {"content-type" => "application/json"}}
          ).with { |req|
          requests << JSON.parse(req.body)
          true
        }

        client.chat_with_tools(messages, registry: registry, session_id: session.id)

        second_request = requests.last
        last_user_msg = second_request["messages"].last
        expect(last_user_msg["role"]).to eq("user")
        expect(last_user_msg["content"]).to include(
          hash_including("type" => "tool_result", "tool_use_id" => "toolu_abc123")
        )
      end
    end

    context "when the tool returns an error" do
      let(:failing_tool_class) do
        Class.new(Tools::Base) do
          def self.tool_name = "web_get"
          def self.description = "Fetch URL"
          def self.input_schema = {type: "object", properties: {url: {type: "string"}}, required: ["url"]}

          def execute(_input)
            {error: "Connection refused"}
          end
        end
      end

      let(:tool_use_response) do
        {
          id: "msg_tool",
          type: "message",
          role: "assistant",
          content: [
            {type: "tool_use", id: "toolu_err", name: "web_get", input: {url: "https://down.com"}}
          ],
          model: "claude-sonnet-4-20250514",
          stop_reason: "tool_use",
          usage: {input_tokens: 20, output_tokens: 30}
        }
      end

      let(:final_response) do
        {
          id: "msg_final",
          type: "message",
          role: "assistant",
          content: [{type: "text", text: "Sorry, I could not fetch that URL."}],
          model: "claude-sonnet-4-20250514",
          stop_reason: "end_turn",
          usage: {input_tokens: 50, output_tokens: 20}
        }
      end

      before do
        error_registry = Tools::Registry.new
        error_registry.register(failing_tool_class)
        @error_registry = error_registry

        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_return(
            {status: 200, body: tool_use_response.to_json, headers: {"content-type" => "application/json"}},
            {status: 200, body: final_response.to_json, headers: {"content-type" => "application/json"}}
          )
      end

      it "emits ToolResponse with success: false for error results" do
        events = []
        subscriber = double("sub")
        allow(subscriber).to receive(:emit) { |e| events << e }
        Events::Bus.subscribe(subscriber)

        client.chat_with_tools(messages, registry: @error_registry, session_id: session.id)

        tool_response = events.find { |e| e[:payload][:type] == "tool_response" }
        expect(tool_response[:payload][:success]).to be false
      ensure
        Events::Bus.unsubscribe(subscriber)
      end
    end

    context "when the tool raises an unexpected exception" do
      let(:exploding_tool_class) do
        Class.new(Tools::Base) do
          def self.tool_name = "web_get"
          def self.description = "Fetch URL"
          def self.input_schema = {type: "object", properties: {url: {type: "string"}}, required: ["url"]}

          def execute(_input)
            raise "something went terribly wrong"
          end
        end
      end

      let(:tool_use_response) do
        {
          id: "msg_tool",
          type: "message",
          role: "assistant",
          content: [
            {type: "tool_use", id: "toolu_boom", name: "web_get", input: {url: "https://boom.com"}}
          ],
          model: "claude-sonnet-4-20250514",
          stop_reason: "tool_use",
          usage: {input_tokens: 20, output_tokens: 30}
        }
      end

      let(:final_response) do
        {
          id: "msg_final",
          type: "message",
          role: "assistant",
          content: [{type: "text", text: "That tool failed, sorry."}],
          model: "claude-sonnet-4-20250514",
          stop_reason: "end_turn",
          usage: {input_tokens: 50, output_tokens: 20}
        }
      end

      before do
        exploding_registry = Tools::Registry.new
        exploding_registry.register(exploding_tool_class)
        @exploding_registry = exploding_registry

        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_return(
            {status: 200, body: tool_use_response.to_json, headers: {"content-type" => "application/json"}},
            {status: 200, body: final_response.to_json, headers: {"content-type" => "application/json"}}
          )
      end

      it "catches the exception and returns an error tool_result to the LLM" do
        result = client.chat_with_tools(messages, registry: @exploding_registry, session_id: session.id)

        expect(result).to eq("That tool failed, sorry.")
      end

      it "emits ToolResponse with success: false" do
        events = []
        subscriber = double("sub")
        allow(subscriber).to receive(:emit) { |e| events << e }
        Events::Bus.subscribe(subscriber)

        client.chat_with_tools(messages, registry: @exploding_registry, session_id: session.id)

        tool_response = events.find { |e| e[:payload][:type] == "tool_response" }
        expect(tool_response[:payload][:success]).to be false
        expect(tool_response[:payload][:content]).to include("RuntimeError")
        expect(tool_response[:payload][:content]).to include("something went terribly wrong")
      ensure
        Events::Bus.unsubscribe(subscriber)
      end
    end

    context "when the user interrupts during tool execution" do
      let(:tool_use_response) do
        {
          id: "msg_tool",
          type: "message",
          role: "assistant",
          content: [
            {type: "tool_use", id: "toolu_int1", name: "web_get", input: {url: "https://first.com"}},
            {type: "tool_use", id: "toolu_int2", name: "web_get", input: {url: "https://second.com"}}
          ],
          model: "claude-sonnet-4-20250514",
          stop_reason: "tool_use",
          usage: {input_tokens: 20, output_tokens: 30}
        }
      end

      before do
        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_return(
            status: 200,
            body: tool_use_response.to_json,
            headers: {"content-type" => "application/json"}
          )
      end

      it "returns nil when interrupted after tools" do
        session.update_column(:interrupt_requested, true)

        result = client.chat_with_tools(messages, registry: registry, session_id: session.id)
        expect(result).to be_nil
      end

      it "creates synthetic 'Stopped by user' tool_results for interrupted tools" do
        session.update_column(:interrupt_requested, true)

        events = []
        subscriber = double("sub")
        allow(subscriber).to receive(:emit) { |e| events << e }
        Events::Bus.subscribe(subscriber)

        client.chat_with_tools(messages, registry: registry, session_id: session.id)

        tool_responses = events.select { |e| e[:payload][:type] == "tool_response" }
        expect(tool_responses.size).to eq(2)
        tool_responses.each do |resp|
          expect(resp[:payload][:content]).to eq(LLM::Client::INTERRUPT_MESSAGE)
          expect(resp[:payload][:success]).to be false
        end
      ensure
        Events::Bus.unsubscribe(subscriber)
      end

      it "emits ToolCall events for interrupted tools" do
        session.update_column(:interrupt_requested, true)

        events = []
        subscriber = double("sub")
        allow(subscriber).to receive(:emit) { |e| events << e }
        Events::Bus.subscribe(subscriber)

        client.chat_with_tools(messages, registry: registry, session_id: session.id)

        tool_calls = events.select { |e| e[:payload][:type] == "tool_call" }
        expect(tool_calls.size).to eq(2)
        expect(tool_calls.map { |e| e[:payload][:tool_use_id] }).to eq(%w[toolu_int1 toolu_int2])
      ensure
        Events::Bus.unsubscribe(subscriber)
      end

      it "clears the interrupt flag" do
        session.update_column(:interrupt_requested, true)

        client.chat_with_tools(messages, registry: registry, session_id: session.id)

        expect(session.reload.interrupt_requested?).to be false
      end

      it "executes first tool then interrupts remaining when flag arrives mid-execution" do
        sid = session.id
        tool_class.define_method(:execute) do |_input|
          Session.where(id: sid).update_all(interrupt_requested: true)
          "first result"
        end

        events = []
        subscriber = double("sub")
        allow(subscriber).to receive(:emit) { |e| events << e }
        Events::Bus.subscribe(subscriber)

        client.chat_with_tools(messages, registry: registry, session_id: session.id)

        tool_responses = events.select { |e| e[:payload][:type] == "tool_response" }
        expect(tool_responses.size).to eq(2)
        expect(tool_responses[0][:payload][:content]).to eq("first result")
        expect(tool_responses[0][:payload][:success]).to be true
        expect(tool_responses[1][:payload][:content]).to eq(LLM::Client::INTERRUPT_MESSAGE)
        expect(tool_responses[1][:payload][:success]).to be false
      ensure
        Events::Bus.unsubscribe(subscriber)
      end

      it "does not make another LLM API call after interrupt" do
        session.update_column(:interrupt_requested, true)

        client.chat_with_tools(messages, registry: registry, session_id: session.id)

        # Only one API call should have been made (the initial one that returned tool_use)
        expect(WebMock).to have_requested(:post, "https://api.anthropic.com/v1/messages").once
      end

      context "with a single tool_use in the response" do
        let(:tool_use_response) do
          {
            id: "msg_tool",
            type: "message",
            role: "assistant",
            content: [
              {type: "tool_use", id: "toolu_single", name: "web_get", input: {url: "https://only.com"}}
            ],
            model: "claude-sonnet-4-20250514",
            stop_reason: "tool_use",
            usage: {input_tokens: 20, output_tokens: 30}
          }
        end

        it "interrupts the single tool without executing it" do
          session.update_column(:interrupt_requested, true)

          events = []
          subscriber = double("sub")
          allow(subscriber).to receive(:emit) { |e| events << e }
          Events::Bus.subscribe(subscriber)

          result = client.chat_with_tools(messages, registry: registry, session_id: session.id)

          expect(result).to be_nil
          tool_responses = events.select { |e| e[:payload][:type] == "tool_response" }
          expect(tool_responses.size).to eq(1)
          expect(tool_responses[0][:payload][:content]).to eq(LLM::Client::INTERRUPT_MESSAGE)
          expect(tool_responses[0][:payload][:success]).to be false
        ensure
          Events::Bus.unsubscribe(subscriber)
        end
      end
    end

    context "when the tool loop exceeds max_tool_rounds" do
      let(:tool_use_response) do
        {
          id: "msg_tool",
          type: "message",
          role: "assistant",
          content: [
            {type: "tool_use", id: "toolu_loop", name: "web_get", input: {url: "https://loop.com"}}
          ],
          model: "claude-sonnet-4-20250514",
          stop_reason: "tool_use",
          usage: {input_tokens: 20, output_tokens: 30}
        }
      end

      before do
        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_return(
            status: 200,
            body: tool_use_response.to_json,
            headers: {"content-type" => "application/json"}
          )
      end

      it "halts and returns an error message" do
        result = client.chat_with_tools(messages, registry: registry, session_id: session.id)
        expect(result).to include("Tool loop exceeded")
      end
    end
  end
end
