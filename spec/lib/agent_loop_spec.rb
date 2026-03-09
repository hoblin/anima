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

    it "passes session messages to the LLM client" do
      session.events.create!(event_type: "user_message", payload: {"content" => "previous"}, timestamp: 1)
      session.events.create!(event_type: "agent_message", payload: {"content" => "old reply"}, timestamp: 2)

      received_messages = nil
      allow(client).to receive(:chat_with_tools) { |msgs, **_|
        received_messages = msgs.dup
        "response"
      }

      agent_loop.process("new question")

      expect(received_messages).to include(
        {role: "user", content: "previous"},
        {role: "assistant", content: "old reply"}
      )
    end

    it "passes the tool registry to the LLM client" do
      allow(client).to receive(:chat_with_tools) do |_msgs, registry:, **_|
        expect(registry).to be_a(Tools::Registry)
        expect(registry.registered?("bash")).to be true
        expect(registry.registered?("web_get")).to be true
        "ok"
      end

      agent_loop.process("test")
    end

    it "passes the session_id to the LLM client" do
      allow(client).to receive(:chat_with_tools) do |_msgs, session_id:, **_|
        expect(session_id).to eq(session.id)
        "ok"
      end

      agent_loop.process("test")
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

        expect(collector.messages.last).to eq({role: "assistant", content: "Error: Connection failed"})
        Events::Bus.unsubscribe(collector)
      end

      it "returns the error message" do
        expect(agent_loop.process("hi")).to eq("Error: Connection failed")
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

  describe "#finalize" do
    it "finalizes the shell session" do
      mock_shell = instance_double(ShellSession)
      allow(mock_shell).to receive(:finalize)

      loop = described_class.new(session: session, shell_session: mock_shell, client: client)
      loop.finalize

      expect(mock_shell).to have_received(:finalize)
    end
  end
end
