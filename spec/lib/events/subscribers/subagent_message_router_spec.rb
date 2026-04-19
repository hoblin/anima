# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::Subscribers::SubagentMessageRouter do
  subject(:router) { described_class.new }

  describe "child → parent routing" do
    let(:parent) { Session.create! }
    let(:child) { Session.create!(parent_session: parent, prompt: "sub-agent", name: "loop-sleuth") }

    it "creates a subagent PendingMessage on the parent" do
      event = Events::AgentMessage.new(content: "Here's my analysis.", session_id: child.id)
      router.emit(name: event.event_name, payload: event.to_h)

      pm = parent.pending_messages.last
      expect(pm.content).to eq("Here's my analysis.")
      expect(pm.source_type).to eq("subagent")
      expect(pm.source_name).to eq("loop-sleuth")
      expect(pm.message_type).to eq("subagent")
      expect(pm.kind).to eq("active")
    end

    it "falls back to agent-N when child has no name" do
      unnamed = Session.create!(parent_session: parent, prompt: "sub-agent")

      event = Events::AgentMessage.new(content: "Result", session_id: unnamed.id)
      router.emit(name: event.event_name, payload: event.to_h)

      pm = parent.pending_messages.last
      expect(pm.source_name).to eq("agent-#{unnamed.id}")
    end

    it "does not persist a Message directly — promotion is DrainJob's job" do
      event = Events::AgentMessage.new(content: "Here's my analysis.", session_id: child.id)
      router.emit(name: event.event_name, payload: event.to_h)

      expect(parent.messages.count).to eq(0)
    end

    it "ignores non-agent_message events" do
      event = Events::UserMessage.new(content: "hi", session_id: child.id)
      router.emit(name: event.event_name, payload: event.to_h)

      expect(parent.pending_messages.count).to eq(0)
    end

    it "ignores events with empty content" do
      event = Events::AgentMessage.new(content: "", session_id: child.id)
      router.emit(name: event.event_name, payload: event.to_h)

      expect(parent.pending_messages.count).to eq(0)
    end

    it "ignores events with missing session" do
      event = Events::AgentMessage.new(content: "hello", session_id: -1)
      expect { router.emit(name: event.event_name, payload: event.to_h) }.not_to raise_error
    end
  end

  describe "parent → child routing (@mentions)" do
    let(:parent) { Session.create! }
    let!(:child_a) { Session.create!(parent_session: parent, prompt: "sub-agent", name: "loop-sleuth") }
    let!(:child_b) { Session.create!(parent_session: parent, prompt: "sub-agent", name: "api-scout") }

    it "routes @mention to the matching child as a PendingMessage with parent attribution" do
      event = Events::AgentMessage.new(
        content: "@loop-sleuth Check the edit tool next.",
        session_id: parent.id
      )
      router.emit(name: event.event_name, payload: event.to_h)

      pm = child_a.pending_messages.last
      expect(pm).to be_present
      expect(pm.content).to eq("[from parent]: @loop-sleuth Check the edit tool next.")
    end

    it "routes to multiple mentioned children" do
      event = Events::AgentMessage.new(
        content: "@loop-sleuth finish up, @api-scout start searching",
        session_id: parent.id
      )
      router.emit(name: event.event_name, payload: event.to_h)

      expect(child_a.pending_messages.count).to eq(1)
      expect(child_b.pending_messages.count).to eq(1)
    end

    it "ignores @mentions that don't match any child" do
      event = Events::AgentMessage.new(
        content: "@unknown-agent do something",
        session_id: parent.id
      )
      router.emit(name: event.event_name, payload: event.to_h)

      expect(child_a.pending_messages.count).to eq(0)
      expect(child_b.pending_messages.count).to eq(0)
    end

    it "does not route when message has no @mentions" do
      event = Events::AgentMessage.new(
        content: "I'll think about it and get back to you.",
        session_id: parent.id
      )
      router.emit(name: event.event_name, payload: event.to_h)

      expect(child_a.pending_messages.count).to eq(0)
    end

    it "does not route to children without names" do
      unnamed = Session.create!(parent_session: parent, prompt: "sub-agent")

      event = Events::AgentMessage.new(
        content: "hey @#{unnamed.id} do something",
        session_id: parent.id
      )
      router.emit(name: event.event_name, payload: event.to_h)

      expect(unnamed.pending_messages.count).to eq(0)
    end
  end
end
