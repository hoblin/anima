# frozen_string_literal: true

require "rails_helper"

RSpec.describe Session do
  describe "validations" do
    it "accepts valid view modes" do
      session = Session.new
      %w[basic verbose debug].each do |mode|
        session.view_mode = mode
        expect(session).to be_valid
      end
    end

    it "rejects invalid view modes" do
      session = Session.new(view_mode: "fancy")
      expect(session).not_to be_valid
      expect(session.errors[:view_mode]).to be_present
    end

    it "defaults view_mode to basic" do
      session = Session.create!
      expect(session.view_mode).to eq("basic")
    end
  end

  describe "#next_view_mode" do
    it "cycles basic → verbose" do
      session = Session.new(view_mode: "basic")
      expect(session.next_view_mode).to eq("verbose")
    end

    it "cycles verbose → debug" do
      session = Session.new(view_mode: "verbose")
      expect(session.next_view_mode).to eq("debug")
    end

    it "cycles debug → basic" do
      session = Session.new(view_mode: "debug")
      expect(session.next_view_mode).to eq("basic")
    end
  end

  describe "associations" do
    it "has many events ordered by id" do
      session = Session.create!
      event_a = session.events.create!(event_type: "user_message", payload: {content: "first"}, timestamp: 1)
      event_b = session.events.create!(event_type: "user_message", payload: {content: "second"}, timestamp: 2)

      expect(session.events.reload).to eq([event_a, event_b])
    end

    it "destroys events when session is destroyed" do
      session = Session.create!
      session.events.create!(event_type: "user_message", payload: {content: "hi"}, timestamp: 1)

      expect { session.destroy }.to change(Event, :count).by(-1)
    end

    it "belongs to parent_session (optional)" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "test prompt")

      expect(child.parent_session).to eq(parent)
    end

    it "allows sessions without a parent" do
      session = Session.create!
      expect(session.parent_session).to be_nil
    end

    it "has many child_sessions" do
      parent = Session.create!
      child_a = Session.create!(parent_session: parent, prompt: "agent A")
      child_b = Session.create!(parent_session: parent, prompt: "agent B")

      expect(parent.child_sessions).to contain_exactly(child_a, child_b)
    end

    it "destroys child sessions when parent is destroyed" do
      parent = Session.create!
      Session.create!(parent_session: parent, prompt: "child")

      expect { parent.destroy }.to change(Session, :count).by(-2)
    end
  end

  describe "#sub_agent?" do
    it "returns true for child sessions" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "task")

      expect(child).to be_sub_agent
    end

    it "returns false for main sessions" do
      session = Session.create!
      expect(session).not_to be_sub_agent
    end
  end

  describe "#system_prompt" do
    it "returns prompt for sub-agent sessions" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "You are a research assistant.")

      expect(child.system_prompt).to eq("You are a research assistant.")
    end

    it "returns nil for main sessions" do
      session = Session.create!
      expect(session.system_prompt).to be_nil
    end
  end

  describe "#messages_for_llm" do
    let(:session) { Session.create! }

    it "returns user_message events with user role" do
      session.events.create!(event_type: "user_message", payload: {"content" => "hello"}, timestamp: 1)

      expect(session.messages_for_llm).to eq([{role: "user", content: "hello"}])
    end

    it "returns agent_message events with assistant role" do
      session.events.create!(event_type: "agent_message", payload: {"content" => "hi there"}, timestamp: 1)

      expect(session.messages_for_llm).to eq([{role: "assistant", content: "hi there"}])
    end

    it "excludes system_message events" do
      session.events.create!(event_type: "system_message", payload: {"content" => "boot"}, timestamp: 1)

      expect(session.messages_for_llm).to be_empty
    end

    context "with tool events" do
      it "assembles tool_call events as assistant messages with tool_use blocks" do
        session.events.create!(
          event_type: "tool_call",
          payload: {"content" => "Calling web_get", "tool_name" => "web_get",
                    "tool_input" => {"url" => "https://example.com"}, "tool_use_id" => "toolu_123"},
          timestamp: 1
        )

        result = session.messages_for_llm
        expect(result).to eq([
          {role: "assistant", content: [
            {type: "tool_use", id: "toolu_123", name: "web_get", input: {"url" => "https://example.com"}}
          ]}
        ])
      end

      it "assembles tool_response events as user messages with tool_result blocks" do
        session.events.create!(
          event_type: "tool_response",
          payload: {"content" => "<html>hello</html>", "tool_name" => "web_get",
                    "tool_use_id" => "toolu_123", "success" => true},
          timestamp: 1
        )

        result = session.messages_for_llm
        expect(result).to eq([
          {role: "user", content: [
            {type: "tool_result", tool_use_id: "toolu_123", content: "<html>hello</html>"}
          ]}
        ])
      end

      it "groups consecutive tool_call events into one assistant message" do
        session.events.create!(
          event_type: "tool_call",
          payload: {"content" => "Calling web_get", "tool_name" => "web_get",
                    "tool_input" => {"url" => "https://a.com"}, "tool_use_id" => "toolu_1"},
          timestamp: 1
        )
        session.events.create!(
          event_type: "tool_call",
          payload: {"content" => "Calling web_get", "tool_name" => "web_get",
                    "tool_input" => {"url" => "https://b.com"}, "tool_use_id" => "toolu_2"},
          timestamp: 2
        )

        result = session.messages_for_llm
        expect(result.length).to eq(1)
        expect(result.first[:role]).to eq("assistant")
        expect(result.first[:content].length).to eq(2)
      end

      it "groups consecutive tool_response events into one user message" do
        session.events.create!(
          event_type: "tool_response",
          payload: {"content" => "page A", "tool_name" => "web_get", "tool_use_id" => "toolu_1"},
          timestamp: 1
        )
        session.events.create!(
          event_type: "tool_response",
          payload: {"content" => "page B", "tool_name" => "web_get", "tool_use_id" => "toolu_2"},
          timestamp: 2
        )

        result = session.messages_for_llm
        expect(result.length).to eq(1)
        expect(result.first[:role]).to eq("user")
        expect(result.first[:content].length).to eq(2)
      end

      it "assembles a full tool conversation correctly" do
        session.events.create!(event_type: "user_message", payload: {"content" => "what is on example.com?"}, timestamp: 1)
        session.events.create!(
          event_type: "tool_call",
          payload: {"content" => "Calling web_get", "tool_name" => "web_get",
                    "tool_input" => {"url" => "https://example.com"}, "tool_use_id" => "toolu_abc"},
          timestamp: 2
        )
        session.events.create!(
          event_type: "tool_response",
          payload: {"content" => "<html>Example Domain</html>", "tool_name" => "web_get",
                    "tool_use_id" => "toolu_abc", "success" => true},
          timestamp: 3
        )
        session.events.create!(event_type: "agent_message", payload: {"content" => "The page says Example Domain."}, timestamp: 4)

        result = session.messages_for_llm
        expect(result).to eq([
          {role: "user", content: "what is on example.com?"},
          {role: "assistant", content: [
            {type: "tool_use", id: "toolu_abc", name: "web_get", input: {"url" => "https://example.com"}}
          ]},
          {role: "user", content: [
            {type: "tool_result", tool_use_id: "toolu_abc", content: "<html>Example Domain</html>"}
          ]},
          {role: "assistant", content: "The page says Example Domain."}
        ])
      end
    end

    it "preserves event order" do
      session.events.create!(event_type: "user_message", payload: {"content" => "first"}, timestamp: 1)
      session.events.create!(event_type: "agent_message", payload: {"content" => "second"}, timestamp: 2)
      session.events.create!(event_type: "user_message", payload: {"content" => "third"}, timestamp: 3)

      expect(session.messages_for_llm).to eq([
        {role: "user", content: "first"},
        {role: "assistant", content: "second"},
        {role: "user", content: "third"}
      ])
    end

    context "with token budget" do
      it "includes all events when within budget" do
        session.events.create!(event_type: "user_message", payload: {"content" => "hi"}, timestamp: 1, token_count: 10)
        session.events.create!(event_type: "agent_message", payload: {"content" => "hello"}, timestamp: 2, token_count: 10)

        expect(session.messages_for_llm(token_budget: 100)).to eq([
          {role: "user", content: "hi"},
          {role: "assistant", content: "hello"}
        ])
      end

      it "drops oldest events when budget exceeded" do
        session.events.create!(event_type: "user_message", payload: {"content" => "old"}, timestamp: 1, token_count: 50)
        session.events.create!(event_type: "agent_message", payload: {"content" => "old reply"}, timestamp: 2, token_count: 50)
        session.events.create!(event_type: "user_message", payload: {"content" => "recent"}, timestamp: 3, token_count: 50)
        session.events.create!(event_type: "agent_message", payload: {"content" => "recent reply"}, timestamp: 4, token_count: 50)

        result = session.messages_for_llm(token_budget: 100)

        expect(result).to eq([
          {role: "user", content: "recent"},
          {role: "assistant", content: "recent reply"}
        ])
      end

      it "always includes at least the newest event even if it exceeds budget" do
        session.events.create!(event_type: "user_message", payload: {"content" => "big message"}, timestamp: 1, token_count: 500)

        result = session.messages_for_llm(token_budget: 100)

        expect(result).to eq([{role: "user", content: "big message"}])
      end

      it "uses heuristic estimate for events with zero token_count" do
        session.events.create!(event_type: "user_message", payload: {"content" => "x" * 400}, timestamp: 1, token_count: 0)
        session.events.create!(event_type: "user_message", payload: {"content" => "recent"}, timestamp: 2, token_count: 10)

        # "x" * 400 => ~100 token estimate, plus 10 = 110, fits in 200
        result = session.messages_for_llm(token_budget: 200)
        expect(result.length).to eq(2)
      end

      it "returns events in chronological order" do
        session.events.create!(event_type: "user_message", payload: {"content" => "first"}, timestamp: 1, token_count: 10)
        session.events.create!(event_type: "agent_message", payload: {"content" => "second"}, timestamp: 2, token_count: 10)
        session.events.create!(event_type: "user_message", payload: {"content" => "third"}, timestamp: 3, token_count: 10)

        result = session.messages_for_llm(token_budget: 30)

        expect(result.map { |m| m[:content] }).to eq(%w[first second third])
      end
    end
  end

  describe "#promote_pending_messages!" do
    let(:session) { Session.create! }

    it "promotes pending user messages to delivered (nil status)" do
      event = session.events.create!(
        event_type: "user_message",
        payload: {"content" => "queued", "status" => "pending"},
        timestamp: 1,
        status: "pending"
      )

      session.promote_pending_messages!

      event.reload
      expect(event.status).to be_nil
      expect(event.payload).not_to have_key("status")
    end

    it "returns the count of promoted messages" do
      session.events.create!(event_type: "user_message", payload: {"content" => "q1", "status" => "pending"}, timestamp: 1, status: "pending")
      session.events.create!(event_type: "user_message", payload: {"content" => "q2", "status" => "pending"}, timestamp: 2, status: "pending")

      expect(session.promote_pending_messages!).to eq(2)
    end

    it "returns zero when no pending messages exist" do
      session.events.create!(event_type: "user_message", payload: {"content" => "done"}, timestamp: 1)

      expect(session.promote_pending_messages!).to eq(0)
    end

    it "does not affect non-pending events" do
      delivered = session.events.create!(event_type: "user_message", payload: {"content" => "done"}, timestamp: 1)
      session.events.create!(event_type: "user_message", payload: {"content" => "q", "status" => "pending"}, timestamp: 2, status: "pending")

      session.promote_pending_messages!

      expect(delivered.reload.status).to be_nil
    end
  end

  describe "#messages_for_llm with pending messages" do
    let(:session) { Session.create! }

    it "excludes pending messages from LLM context" do
      session.events.create!(event_type: "user_message", payload: {"content" => "delivered"}, timestamp: 1)
      session.events.create!(event_type: "user_message", payload: {"content" => "queued", "status" => "pending"}, timestamp: 2, status: "pending")

      result = session.messages_for_llm
      expect(result).to eq([{role: "user", content: "delivered"}])
    end
  end

  describe "#viewport_events with pending messages" do
    let(:session) { Session.create! }

    it "includes pending messages by default (for display)" do
      session.events.create!(event_type: "user_message", payload: {"content" => "delivered"}, timestamp: 1, token_count: 10)
      session.events.create!(event_type: "user_message", payload: {"content" => "queued"}, timestamp: 2, status: "pending", token_count: 10)

      events = session.viewport_events
      expect(events.map { |e| e.payload["content"] }).to eq(%w[delivered queued])
    end

    it "excludes pending messages when include_pending is false" do
      session.events.create!(event_type: "user_message", payload: {"content" => "delivered"}, timestamp: 1, token_count: 10)
      session.events.create!(event_type: "user_message", payload: {"content" => "queued"}, timestamp: 2, status: "pending", token_count: 10)

      events = session.viewport_events(include_pending: false)
      expect(events.map { |e| e.payload["content"] }).to eq(%w[delivered])
    end
  end

  describe "virtual viewport inheritance" do
    let(:parent) { Session.create! }
    let(:child) do
      # Ensure parent events have earlier created_at
      Session.create!(parent_session: parent, prompt: "sub-agent prompt")
    end

    before do
      # Parent conversation history (created before child session)
      parent.events.create!(event_type: "user_message", payload: {"content" => "parent msg 1"}, timestamp: 1, token_count: 10)
      parent.events.create!(event_type: "agent_message", payload: {"content" => "parent reply 1"}, timestamp: 2, token_count: 10)
    end

    it "includes parent events before child events for sub-agent sessions" do
      child.events.create!(event_type: "user_message", payload: {"content" => "child task"}, timestamp: 3, token_count: 10)

      events = child.viewport_events
      contents = events.map { |e| e.payload["content"] }

      expect(contents).to eq(["parent msg 1", "parent reply 1", "child task"])
    end

    it "shows parent events first chronologically, then child events" do
      child.events.create!(event_type: "user_message", payload: {"content" => "task"}, timestamp: 3, token_count: 10)
      child.events.create!(event_type: "agent_message", payload: {"content" => "working..."}, timestamp: 4, token_count: 10)

      events = child.viewport_events
      sessions = events.map(&:session_id)

      # Parent events come first, then child events
      parent_indices = sessions.each_index.select { |i| sessions[i] == parent.id }
      child_indices = sessions.each_index.select { |i| sessions[i] == child.id }
      expect(parent_indices.max).to be < child_indices.min
    end

    it "respects token budget for combined viewport" do
      child.events.create!(event_type: "user_message", payload: {"content" => "task"}, timestamp: 3, token_count: 50)

      # Budget of 60: child event (50) + one parent event (10), but not both parent events (20)
      events = child.viewport_events(token_budget: 60)
      contents = events.map { |e| e.payload["content"] }

      expect(contents).to include("task")
      expect(contents.length).to eq(2) # child + 1 parent event
    end

    it "prioritizes child events over parent events" do
      child.events.create!(event_type: "user_message", payload: {"content" => "task"}, timestamp: 3, token_count: 50)

      # Budget only fits the child event
      events = child.viewport_events(token_budget: 50)
      contents = events.map { |e| e.payload["content"] }

      expect(contents).to eq(["task"])
    end

    it "does not inherit events from parent for main sessions" do
      main = Session.create!
      main.events.create!(event_type: "user_message", payload: {"content" => "only mine"}, timestamp: 1, token_count: 10)

      events = main.viewport_events
      expect(events.length).to eq(1)
      expect(events.first.payload["content"]).to eq("only mine")
    end

    it "excludes parent events created after the child session" do
      child.events.create!(event_type: "user_message", payload: {"content" => "task"}, timestamp: 3, token_count: 10)

      # Parent event with created_at well after child — should not be inherited
      parent.events.create!(
        event_type: "agent_message",
        payload: {"content" => "parent continues"},
        timestamp: 4, token_count: 10,
        created_at: child.created_at + 1.second
      )

      events = child.viewport_events
      contents = events.map { |e| e.payload["content"] }

      expect(contents).not_to include("parent continues")
    end

    it "trims trailing tool_call events from parent viewport" do
      parent.events.create!(
        event_type: "tool_call",
        payload: {"content" => "Calling spawn_subagent", "tool_name" => "spawn_subagent",
                  "tool_input" => {"task" => "research"}, "tool_use_id" => "toolu_orphan"},
        timestamp: 3, token_count: 10
      )

      child.events.create!(event_type: "user_message", payload: {"content" => "task"}, timestamp: 4, token_count: 10)

      events = child.viewport_events
      types = events.map(&:event_type)

      # The orphaned tool_call at the end of parent events should be trimmed
      expect(types).not_to include("tool_call")
    end
  end

  describe "#estimate_tokens (private)" do
    let(:session) { Session.create! }

    it "delegates to Event#estimate_tokens" do
      event = session.events.create!(
        event_type: "user_message", payload: {"content" => "hello world"}, timestamp: 1
      )

      expect(session.send(:estimate_tokens, event)).to eq(event.estimate_tokens)
    end

    it "uses heuristic for tool events via Event#estimate_tokens" do
      event = session.events.create!(
        event_type: "tool_call",
        payload: {"content" => "calling", "tool_name" => "bash", "tool_input" => {"command" => "ls"}},
        timestamp: 1
      )

      expect(session.send(:estimate_tokens, event)).to eq(event.estimate_tokens)
    end
  end
end
