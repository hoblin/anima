# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::Subscribers::Persister do
  let(:session) { Session.create! }

  subject(:persister) { described_class.new(session) }

  after { Events::Bus.unsubscribe(persister) }

  describe "#emit" do
    it "persists user_message events" do
      Events::Bus.subscribe(persister)
      Events::Bus.emit(Events::UserMessage.new(content: "hello", session_id: session.id))

      expect(session.events.count).to eq(1)
      event = session.events.first
      expect(event.event_type).to eq("user_message")
      expect(event.payload["content"]).to eq("hello")
    end

    it "persists agent_message events" do
      Events::Bus.subscribe(persister)
      Events::Bus.emit(Events::AgentMessage.new(content: "hi there", session_id: session.id))

      event = session.events.first
      expect(event.event_type).to eq("agent_message")
      expect(event.payload["content"]).to eq("hi there")
    end

    it "persists system_message events" do
      Events::Bus.subscribe(persister)
      Events::Bus.emit(Events::SystemMessage.new(content: "boot", session_id: session.id))

      event = session.events.first
      expect(event.event_type).to eq("system_message")
    end

    it "persists tool_call events with tool metadata" do
      Events::Bus.subscribe(persister)
      Events::Bus.emit(Events::ToolCall.new(content: "running", tool_name: "bash", tool_input: {cmd: "ls"}, session_id: session.id))

      event = session.events.first
      expect(event.event_type).to eq("tool_call")
      expect(event.payload["tool_name"]).to eq("bash")
      expect(event.payload["tool_input"]).to eq({"cmd" => "ls"})
    end

    it "persists tool_response events" do
      Events::Bus.subscribe(persister)
      Events::Bus.emit(Events::ToolResponse.new(content: "output", tool_name: "bash", success: true, session_id: session.id))

      event = session.events.first
      expect(event.event_type).to eq("tool_response")
      expect(event.payload["tool_name"]).to eq("bash")
      expect(event.payload["success"]).to be true
    end

    it "auto-increments position across events" do
      Events::Bus.subscribe(persister)
      Events::Bus.emit(Events::UserMessage.new(content: "first", session_id: session.id))
      Events::Bus.emit(Events::AgentMessage.new(content: "second", session_id: session.id))
      Events::Bus.emit(Events::UserMessage.new(content: "third", session_id: session.id))

      positions = session.events.reload.pluck(:position)
      expect(positions).to eq([0, 1, 2])
    end

    it "preserves nanosecond timestamps" do
      Events::Bus.subscribe(persister)
      Events::Bus.emit(Events::UserMessage.new(content: "hello", session_id: session.id))

      event = session.events.first
      expect(event.timestamp).to be_a(Integer)
      expect(event.timestamp).to be > 0
    end

    it "ignores events with nil payload" do
      persister.emit({payload: nil})
      expect(session.events.count).to eq(0)
    end

    it "ignores events with missing type" do
      persister.emit({payload: {content: "orphan"}})
      expect(session.events.count).to eq(0)
    end
  end

  describe "#session=" do
    it "switches to a new session" do
      new_session = Session.create!
      Events::Bus.subscribe(persister)

      persister.session = new_session
      Events::Bus.emit(Events::UserMessage.new(content: "hello", session_id: new_session.id))

      expect(new_session.events.count).to eq(1)
      expect(session.events.count).to eq(0)
    end
  end
end
