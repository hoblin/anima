# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::Subscribers::SubagentMessageRouter do
  subject(:router) { described_class.new }

  # The router subscribes to MessageCreated events; its emit contract is
  # +event[:payload][:message] => Message+. Tests dispatch directly to keep
  # assertions on the routing decision, not on Rails.event plumbing.
  def route(message)
    router.emit(name: "anima.message.created", payload: {type: "message.created", message: message})
  end

  def persist_agent_message(session, content)
    session.messages.create!(
      message_type: "agent_message",
      payload: {"type" => "agent_message", "content" => content, "session_id" => session.id},
      timestamp: Time.current.to_ns
    )
  end

  describe "child → parent routing" do
    let(:parent) { Session.create! }
    let(:child) { Session.create!(parent_session: parent, prompt: "sub-agent", name: "loop-sleuth") }

    it "creates a subagent PendingMessage on the parent" do
      route(persist_agent_message(child, "Here's my analysis."))

      pm = parent.pending_messages.last
      expect(pm.content).to eq("Here's my analysis.")
      expect(pm.source_type).to eq("subagent")
      expect(pm.source_name).to eq("loop-sleuth")
      expect(pm.message_type).to eq("subagent")
      expect(pm.kind).to eq("active")
    end

    it "falls back to agent-N when child has no name" do
      unnamed = Session.create!(parent_session: parent, prompt: "sub-agent")

      route(persist_agent_message(unnamed, "Result"))

      pm = parent.pending_messages.last
      expect(pm.source_name).to eq("agent-#{unnamed.id}")
    end

    it "does not persist a second Message on the parent — promotion is DrainJob's job" do
      route(persist_agent_message(child, "Here's my analysis."))

      expect(parent.messages.count).to eq(0)
    end

    it "ignores non-agent_message Messages" do
      user_msg = parent.messages.create!(
        message_type: "user_message",
        payload: {"type" => "user_message", "content" => "hi"},
        timestamp: Time.current.to_ns
      )
      route(user_msg)

      expect(parent.pending_messages.count).to eq(0)
    end

    it "ignores Messages with empty content" do
      route(persist_agent_message(child, ""))

      expect(parent.pending_messages.count).to eq(0)
    end

    it "ignores payloads without a Message" do
      expect {
        router.emit(name: "anima.message.created", payload: {type: "message.created"})
      }.not_to raise_error
    end
  end

  describe "parent → child routing (@mentions)" do
    let(:parent) { Session.create! }
    let!(:child_a) { Session.create!(parent_session: parent, prompt: "sub-agent", name: "loop-sleuth") }
    let!(:child_b) { Session.create!(parent_session: parent, prompt: "sub-agent", name: "api-scout") }

    it "routes @mention to the matching child as a PendingMessage with parent attribution" do
      route(persist_agent_message(parent, "@loop-sleuth Check the edit tool next."))

      pm = child_a.pending_messages.last
      expect(pm).to be_present
      expect(pm.content).to eq("[from parent]: @loop-sleuth Check the edit tool next.")
    end

    it "routes to multiple mentioned children" do
      route(persist_agent_message(parent, "@loop-sleuth finish up, @api-scout start searching"))

      expect(child_a.pending_messages.count).to eq(1)
      expect(child_b.pending_messages.count).to eq(1)
    end

    it "ignores @mentions that don't match any child" do
      route(persist_agent_message(parent, "@unknown-agent do something"))

      expect(child_a.pending_messages.count).to eq(0)
      expect(child_b.pending_messages.count).to eq(0)
    end

    it "does not route when message has no @mentions" do
      route(persist_agent_message(parent, "I'll think about it and get back to you."))

      expect(child_a.pending_messages.count).to eq(0)
    end

    it "does not route to children without names" do
      unnamed = Session.create!(parent_session: parent, prompt: "sub-agent")

      route(persist_agent_message(parent, "hey @#{unnamed.id} do something"))

      expect(unnamed.pending_messages.count).to eq(0)
    end
  end
end
