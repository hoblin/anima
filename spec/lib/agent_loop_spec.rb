# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentLoop do
  let(:session) { Session.create! }
  let(:shell_session) { ShellSession.new(session_id: session.id) }
  let(:client) { double("LLM::Client") }

  subject(:agent_loop) { described_class.new(session: session, shell_session: shell_session, client: client) }

  after { agent_loop.finalize }

  describe "#initialize" do
    it "stores the session" do
      expect(agent_loop.session).to eq(session)
    end

    it "creates a ShellSession when none provided" do
      loop = described_class.new(session: session, client: client)
      expect(loop).to be_a(described_class)
      loop.finalize
    end
  end

  describe "#process" do
    before do
      allow(client).to receive(:chat_with_tools).and_return("Hello back!")
    end

    it "emits a user_message event" do
      collector = Events::Subscribers::MessageCollector.new
      Events::Bus.subscribe(collector)

      agent_loop.process("hi")

      expect(collector.messages.first).to eq({role: "user", content: "hi"})
      Events::Bus.unsubscribe(collector)
    end

    it "emits an agent_message event with the LLM response" do
      collector = Events::Subscribers::MessageCollector.new
      Events::Bus.subscribe(collector)

      agent_loop.process("hi")

      expect(collector.messages.last).to eq({role: "assistant", content: "Hello back!"})
      Events::Bus.unsubscribe(collector)
    end

    it "returns the response text" do
      expect(agent_loop.process("hi")).to eq("Hello back!")
    end

    it "returns nil for empty input" do
      expect(agent_loop.process("")).to be_nil
    end

    it "returns nil for whitespace-only input" do
      expect(agent_loop.process("   ")).to be_nil
    end

    it "does not emit events for empty input" do
      collector = Events::Subscribers::MessageCollector.new
      Events::Bus.subscribe(collector)

      agent_loop.process("")

      expect(collector.messages).to be_empty
      Events::Bus.unsubscribe(collector)
    end

    it "strips whitespace from input before emitting" do
      collector = Events::Subscribers::MessageCollector.new
      Events::Bus.subscribe(collector)

      agent_loop.process("  hello  ")

      expect(collector.messages.first).to eq({role: "user", content: "hello"})
      Events::Bus.unsubscribe(collector)
    end

    context "error handling" do
      before do
        allow(client).to receive(:chat_with_tools).and_raise(StandardError, "Connection failed")
      end

      it "emits error as agent_message event" do
        collector = Events::Subscribers::MessageCollector.new
        Events::Bus.subscribe(collector)

        agent_loop.process("hi")

        expect(collector.messages.last).to eq({role: "assistant", content: "StandardError: Connection failed"})
        Events::Bus.unsubscribe(collector)
      end

      it "returns the error message" do
        expect(agent_loop.process("hi")).to eq("StandardError: Connection failed")
      end

      it "still emits user_message before the error" do
        collector = Events::Subscribers::MessageCollector.new
        Events::Bus.subscribe(collector)

        agent_loop.process("hi")

        expect(collector.messages.first).to eq({role: "user", content: "hi"})
        Events::Bus.unsubscribe(collector)
      end
    end

    context "multi-turn conversation" do
      let(:persister) { Events::Subscribers::Persister.new(session) }

      before { Events::Bus.subscribe(persister) }
      after { Events::Bus.unsubscribe(persister) }

      it "includes full conversation history in subsequent LLM calls" do
        allow(client).to receive(:chat_with_tools).and_return("First response")
        agent_loop.process("first message")

        received_messages = nil
        allow(client).to receive(:chat_with_tools) { |msgs, **_|
          received_messages = msgs.dup
          "Second response"
        }
        agent_loop.process("second message")

        expect(received_messages).to eq([
          {role: "user", content: "first message"},
          {role: "assistant", content: "First response"},
          {role: "user", content: "second message"}
        ])
      end
    end
  end

  describe "#run" do
    before do
      session.events.create!(event_type: "user_message", payload: {"content" => "hi"}, timestamp: 1)
      allow(client).to receive(:chat_with_tools).and_return("Hello back!")
    end

    it "runs the LLM tool-use loop on persisted session messages" do
      received_messages = nil
      allow(client).to receive(:chat_with_tools) { |msgs, **_|
        received_messages = msgs.dup
        "response"
      }

      agent_loop.run

      expect(received_messages).to include({role: "user", content: "hi"})
    end

    it "emits an agent_message event with the response" do
      collector = Events::Subscribers::MessageCollector.new
      Events::Bus.subscribe(collector)

      agent_loop.run

      expect(collector.messages.last).to eq({role: "assistant", content: "Hello back!"})
      Events::Bus.unsubscribe(collector)
    end

    it "returns the response text" do
      expect(agent_loop.run).to eq("Hello back!")
    end

    it "does not emit a user_message event" do
      collector = Events::Subscribers::MessageCollector.new
      Events::Bus.subscribe(collector)

      agent_loop.run

      user_messages = collector.messages.select { |m| m[:role] == "user" }
      expect(user_messages).to be_empty
      Events::Bus.unsubscribe(collector)
    end

    context "transient errors propagate for retry logic" do
      it "raises TransientError" do
        allow(client).to receive(:chat_with_tools)
          .and_raise(Providers::Anthropic::TransientError, "Connection reset by peer")

        expect { agent_loop.run }.to raise_error(Providers::Anthropic::TransientError)
      end

      it "raises RateLimitError" do
        allow(client).to receive(:chat_with_tools)
          .and_raise(Providers::Anthropic::RateLimitError, "Rate limit exceeded")

        expect { agent_loop.run }.to raise_error(Providers::Anthropic::RateLimitError)
      end

      it "raises ServerError" do
        allow(client).to receive(:chat_with_tools)
          .and_raise(Providers::Anthropic::ServerError, "Anthropic server error")

        expect { agent_loop.run }.to raise_error(Providers::Anthropic::ServerError)
      end
    end

    context "authentication errors propagate" do
      it "raises AuthenticationError" do
        allow(client).to receive(:chat_with_tools)
          .and_raise(Providers::Anthropic::AuthenticationError, "Invalid API key")

        expect { agent_loop.run }.to raise_error(Providers::Anthropic::AuthenticationError)
      end
    end

    it "passes the tool registry to the LLM client" do
      allow(client).to receive(:chat_with_tools) do |_msgs, registry:, **_|
        expect(registry).to be_a(Tools::Registry)
        expect(registry.registered?("bash")).to be true
        expect(registry.registered?("web_get")).to be true
        "ok"
      end

      agent_loop.run
    end

    it "passes the session_id to the LLM client" do
      allow(client).to receive(:chat_with_tools) do |_msgs, session_id:, **_|
        expect(session_id).to eq(session.id)
        "ok"
      end

      agent_loop.run
    end
  end

  describe "#finalize" do
    it "finalizes the shell session" do
      mock_shell = instance_double(ShellSession)
      allow(mock_shell).to receive(:finalize)

      loop = described_class.new(session: session, shell_session: mock_shell, client: client)
      loop.finalize

      expect(mock_shell).to have_received(:finalize)
    end

    it "is safe to call multiple times" do
      mock_shell = instance_double(ShellSession)
      allow(mock_shell).to receive(:finalize)

      loop = described_class.new(session: session, shell_session: mock_shell, client: client)
      loop.finalize
      expect { loop.finalize }.not_to raise_error
    end
  end

  describe "tool registry switching" do
    it "registers spawn_subagent for main sessions" do
      session.events.create!(event_type: "user_message", payload: {"content" => "hi"}, timestamp: 1)
      allow(client).to receive(:chat_with_tools) do |_msgs, registry:, **_|
        expect(registry.registered?("spawn_subagent")).to be true
        expect(registry.registered?("return_result")).to be false
        "ok"
      end

      agent_loop.run
    end

    it "registers return_result for sub-agent sessions" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "sub-agent prompt")
      child.events.create!(event_type: "user_message", payload: {"content" => "task"}, timestamp: 1)

      sub_loop = described_class.new(session: child, shell_session: shell_session, client: client)
      allow(client).to receive(:chat_with_tools) do |_msgs, registry:, **_|
        expect(registry.registered?("return_result")).to be true
        expect(registry.registered?("spawn_subagent")).to be false
        "done"
      end

      sub_loop.run
      sub_loop.finalize
    end
  end

  describe "system prompt" do
    it "passes system_prompt to the LLM client for sub-agent sessions" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "You are a research agent.")
      child.events.create!(event_type: "user_message", payload: {"content" => "task"}, timestamp: 1)

      sub_loop = described_class.new(session: child, shell_session: shell_session, client: client)
      allow(client).to receive(:chat_with_tools) do |_msgs, system:, **_|
        expect(system).to eq("You are a research agent.")
        "done"
      end

      sub_loop.run
      sub_loop.finalize
    end

    it "does not pass system option for main sessions" do
      session.events.create!(event_type: "user_message", payload: {"content" => "hi"}, timestamp: 1)
      allow(client).to receive(:chat_with_tools) do |_msgs, **opts|
        expect(opts).not_to have_key(:system)
        "ok"
      end

      agent_loop.run
    end
  end

  describe "registry injection" do
    it "accepts a custom registry" do
      registry = Tools::Registry.new(context: {shell_session: shell_session})
      registry.register(Tools::WebGet)

      session.events.create!(event_type: "user_message", payload: {"content" => "test"}, timestamp: 1)
      loop = described_class.new(session: session, shell_session: shell_session, client: client, registry: registry)
      allow(client).to receive(:chat_with_tools) do |_msgs, registry:, **_|
        expect(registry.registered?("web_get")).to be true
        expect(registry.registered?("bash")).to be false
        "ok"
      end

      loop.run
      loop.finalize
    end
  end
end
