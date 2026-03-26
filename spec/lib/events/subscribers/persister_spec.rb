# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::Subscribers::Persister do
  let(:session) { Session.create! }

  subject(:persister) { described_class.new(session) }

  after { Events::Bus.unsubscribe(persister) }

  describe "#emit" do
    it "skips non-pending user_message events (job handles persistence)" do
      Events::Bus.subscribe(persister)
      Events::Bus.emit(Events::UserMessage.new(content: "hello", session_id: session.id))

      expect(session.messages.count).to eq(0)
    end

    it "persists agent_message events" do
      Events::Bus.subscribe(persister)
      Events::Bus.emit(Events::AgentMessage.new(content: "hi there", session_id: session.id))

      event = session.messages.first
      expect(event.message_type).to eq("agent_message")
      expect(event.payload["content"]).to eq("hi there")
    end

    it "persists system_message events" do
      Events::Bus.subscribe(persister)
      Events::Bus.emit(Events::SystemMessage.new(content: "boot", session_id: session.id))

      event = session.messages.first
      expect(event.message_type).to eq("system_message")
    end

    it "persists tool_call events with tool metadata and tool_use_id" do
      Events::Bus.subscribe(persister)
      Events::Bus.emit(Events::ToolCall.new(
        content: "running", tool_name: "bash", tool_input: {cmd: "ls"},
        tool_use_id: "toolu_abc123", session_id: session.id
      ))

      event = session.messages.first
      expect(event.message_type).to eq("tool_call")
      expect(event.payload["tool_name"]).to eq("bash")
      expect(event.payload["tool_input"]).to eq({"cmd" => "ls"})
      expect(event.tool_use_id).to eq("toolu_abc123")
    end

    it "persists tool_response events with tool_use_id" do
      Events::Bus.subscribe(persister)
      Events::Bus.emit(Events::ToolResponse.new(
        content: "output", tool_name: "bash", success: true,
        tool_use_id: "toolu_abc123", session_id: session.id
      ))

      event = session.messages.first
      expect(event.message_type).to eq("tool_response")
      expect(event.payload["tool_name"]).to eq("bash")
      expect(event.payload["success"]).to be true
      expect(event.tool_use_id).to eq("toolu_abc123")
    end

    it "preserves event creation order" do
      Events::Bus.subscribe(persister)
      Events::Bus.emit(Events::AgentMessage.new(content: "first", session_id: session.id))
      Events::Bus.emit(Events::SystemMessage.new(content: "second", session_id: session.id))
      Events::Bus.emit(Events::AgentMessage.new(content: "third", session_id: session.id))

      contents = session.messages.reload.pluck(:payload).map { |p| p["content"] }
      expect(contents).to eq(%w[first second third])
    end

    it "persists status field for pending user messages" do
      Events::Bus.subscribe(persister)
      Events::Bus.emit(Events::UserMessage.new(content: "queued", session_id: session.id, status: "pending"))

      event = session.messages.first
      expect(event.status).to eq("pending")
      expect(event.payload["status"]).to eq("pending")
    end

    it "preserves nanosecond timestamps" do
      Events::Bus.subscribe(persister)
      Events::Bus.emit(Events::AgentMessage.new(content: "hello", session_id: session.id))

      event = session.messages.first
      expect(event.timestamp).to be_a(Integer)
      expect(event.timestamp).to be > 0
    end

    it "ignores events with nil payload" do
      persister.emit({payload: nil})
      expect(session.messages.count).to eq(0)
    end

    it "ignores events with missing type" do
      persister.emit({payload: {content: "orphan"}})
      expect(session.messages.count).to eq(0)
    end
  end

  describe "#session=" do
    it "switches to a new session" do
      new_session = Session.create!
      Events::Bus.subscribe(persister)

      persister.session = new_session
      Events::Bus.emit(Events::AgentMessage.new(content: "hello", session_id: new_session.id))

      expect(new_session.messages.count).to eq(1)
      expect(session.messages.count).to eq(0)
    end
  end

  describe "global mode (no session)" do
    subject(:global_persister) { described_class.new }

    after { Events::Bus.unsubscribe(global_persister) }

    it "persists events by looking up session from payload" do
      Events::Bus.subscribe(global_persister)
      Events::Bus.emit(Events::AgentMessage.new(content: "global hello", session_id: session.id))

      expect(session.messages.count).to eq(1)
      expect(session.messages.first.payload["content"]).to eq("global hello")
    end

    it "ignores events with unknown session_id" do
      Events::Bus.subscribe(global_persister)
      Events::Bus.emit(Events::AgentMessage.new(content: "orphan", session_id: 999_999))

      expect(Message.count).to eq(0)
    end

    it "ignores events without session_id" do
      Events::Bus.subscribe(global_persister)
      Events::Bus.emit(Events::AgentMessage.new(content: "no session"))

      expect(Message.count).to eq(0)
    end
  end
end
