# frozen_string_literal: true

require "rails_helper"

RSpec.describe Session do
  # Computes the expected LLM content for a user message with timestamp prefix.
  # Must stay in sync with Session#format_event_time.
  def timestamped(content, timestamp_ns)
    time = Time.at(timestamp_ns / 1_000_000_000.0)
    "#{time.strftime("%a %b %-d %H:%M")}\n#{content}"
  end

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

  describe ".root_sessions" do
    it "returns only sessions without a parent" do
      root = Session.create!
      parent = Session.create!
      Session.create!(parent_session: parent, prompt: "child")

      expect(Session.root_sessions).to contain_exactly(root, parent)
    end
  end

  describe "#name" do
    it "stores agent name for named sub-agents" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "prompt", name: "codebase-analyzer")

      expect(child.reload.name).to eq("codebase-analyzer")
    end

    it "returns nil for unnamed sessions" do
      session = Session.create!
      expect(session.name).to be_nil
    end

    it "rejects names longer than 255 characters" do
      parent = Session.create!
      child = Session.new(parent_session: parent, prompt: "prompt", name: "a" * 256)
      expect(child).not_to be_valid
      expect(child.errors[:name]).to be_present
    end

    it "accepts names up to 255 characters" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "prompt", name: "a" * 255)
      expect(child).to be_valid
    end
  end

  describe "#schedule_analytical_brain!" do
    it "enqueues AnalyticalBrainJob for unnamed root sessions with messages" do
      session = Session.create!
      session.events.create!(event_type: "user_message", payload: {"content" => "hi"}, timestamp: 1)
      session.events.create!(event_type: "agent_message", payload: {"content" => "hello"}, timestamp: 2)

      expect { session.schedule_analytical_brain! }
        .to have_enqueued_job(AnalyticalBrainJob).with(session.id)
    end

    it "does not enqueue for sub-agent sessions" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "task")
      child.events.create!(event_type: "user_message", payload: {"content" => "hi"}, timestamp: 1)
      child.events.create!(event_type: "agent_message", payload: {"content" => "hello"}, timestamp: 2)

      expect { child.schedule_analytical_brain! }
        .not_to have_enqueued_job(AnalyticalBrainJob)
    end

    it "does not enqueue for sessions with fewer than 2 messages" do
      session = Session.create!
      session.events.create!(event_type: "user_message", payload: {"content" => "hi"}, timestamp: 1)

      expect { session.schedule_analytical_brain! }
        .not_to have_enqueued_job(AnalyticalBrainJob)
    end

    it "enqueues at name_generation_interval for named sessions" do
      session = Session.create!(name: "Old Name")
      Anima::Settings.name_generation_interval.times do |i|
        type = i.even? ? "user_message" : "agent_message"
        session.events.create!(event_type: type, payload: {"content" => "msg #{i}"}, timestamp: i + 1)
      end

      expect { session.schedule_analytical_brain! }
        .to have_enqueued_job(AnalyticalBrainJob).with(session.id)
    end

    it "does not enqueue for named sessions between intervals" do
      session = Session.create!(name: "Existing")
      3.times do |i|
        type = i.even? ? "user_message" : "agent_message"
        session.events.create!(event_type: type, payload: {"content" => "msg #{i}"}, timestamp: i + 1)
      end

      expect { session.schedule_analytical_brain! }
        .not_to have_enqueued_job(AnalyticalBrainJob)
    end
  end

  describe "#broadcast_name_update" do
    it "broadcasts name change to the session stream" do
      session = Session.create!

      expect {
        session.update!(name: "🎉 New Name")
      }.to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including(
          "action" => "session_name_updated",
          "session_id" => session.id,
          "name" => "🎉 New Name"
        ))
    end

    it "does not broadcast when name is unchanged" do
      session = Session.create!(name: "Same Name")

      expect {
        session.update!(view_mode: "verbose")
      }.not_to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("action" => "session_name_updated"))
    end
  end

  describe "#broadcast_active_skills_update" do
    it "broadcasts active skills change to the session stream" do
      session = Session.create!

      expect {
        session.update!(active_skills: ["gh-issue", "activerecord"])
      }.to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including(
          "action" => "active_skills_updated",
          "session_id" => session.id,
          "active_skills" => ["gh-issue", "activerecord"]
        ))
    end

    it "does not broadcast when active_skills is unchanged" do
      session = Session.create!(active_skills: ["gh-issue"])

      expect {
        session.update!(name: "New Name")
      }.not_to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("action" => "active_skills_updated"))
    end
  end

  describe "#granted_tools" do
    it "returns nil when not set" do
      session = Session.create!
      expect(session.granted_tools).to be_nil
    end

    it "round-trips an array of tool names through JSON serialization" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "agent", granted_tools: ["read", "web_get"])

      expect(child.reload.granted_tools).to eq(["read", "web_get"])
    end

    it "round-trips an empty array (pure reasoning)" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "thinker", granted_tools: [])

      expect(child.reload.granted_tools).to eq([])
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
    before { Skills::Registry.reload! }

    it "returns prompt for sub-agent sessions" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "You are a research assistant.")

      expect(child.system_prompt).to eq("You are a research assistant.")
    end

    it "returns nil for main sessions with no active skills" do
      session = Session.create!
      expect(session.system_prompt).to be_nil
    end

    it "returns assembled system prompt for main sessions with active skills" do
      session = Session.create!
      session.activate_skill("gh-issue")

      prompt = session.system_prompt
      expect(prompt).to include("Your Expertise")
      expect(prompt).to include("GitHub Issue Writing")
    end
  end

  describe "#activate_skill" do
    before { Skills::Registry.reload! }

    let(:session) { Session.create! }

    it "adds the skill to active_skills" do
      session.activate_skill("gh-issue")

      expect(session.reload.active_skills).to eq(["gh-issue"])
    end

    it "returns the skill definition" do
      result = session.activate_skill("gh-issue")

      expect(result).to be_a(Skills::Definition)
      expect(result.name).to eq("gh-issue")
    end

    it "raises for unknown skills" do
      expect { session.activate_skill("nonexistent") }
        .to raise_error(Skills::InvalidDefinitionError, /Unknown skill/)
    end

    it "is idempotent — does not duplicate" do
      session.activate_skill("gh-issue")
      session.activate_skill("gh-issue")

      expect(session.reload.active_skills).to eq(["gh-issue"])
    end

    it "persists to the database" do
      session.activate_skill("gh-issue")

      reloaded = Session.find(session.id)
      expect(reloaded.active_skills).to eq(["gh-issue"])
    end
  end

  describe "#deactivate_skill" do
    before { Skills::Registry.reload! }

    let(:session) { Session.create! }

    it "removes the skill from active_skills" do
      session.activate_skill("gh-issue")
      session.deactivate_skill("gh-issue")

      expect(session.reload.active_skills).to be_empty
    end

    it "is safe when skill is not active" do
      expect { session.deactivate_skill("nonexistent") }.not_to raise_error
    end

    it "persists to the database" do
      session.activate_skill("gh-issue")
      session.deactivate_skill("gh-issue")

      reloaded = Session.find(session.id)
      expect(reloaded.active_skills).to be_empty
    end
  end

  describe "#assemble_system_prompt" do
    before { Skills::Registry.reload! }

    let(:session) { Session.create! }

    it "returns nil when no skills are active" do
      expect(session.assemble_system_prompt).to be_nil
    end

    it "includes Your Expertise header" do
      session.activate_skill("gh-issue")

      expect(session.assemble_system_prompt).to start_with("## Your Expertise")
    end

    it "includes full skill content" do
      session.activate_skill("gh-issue")

      prompt = session.assemble_system_prompt
      expect(prompt).to include("WHAT/WHY/HOW")
      expect(prompt).to include("Quality Checklist")
    end

    it "uses the first heading from skill content as section title" do
      session.activate_skill("gh-issue")

      prompt = session.assemble_system_prompt
      expect(prompt).to include("### GitHub Issue Writing")
    end

    context "with multiple skills" do
      let(:tmp_dir) { Dir.mktmpdir }

      before do
        File.write(File.join(tmp_dir, "testing.md"), <<~MD)
          ---
          name: testing
          description: "Testing best practices"
          ---

          # Testing Guide

          Write thorough tests.
        MD

        stub_const("Skills::Registry::USER_DIR", tmp_dir)
        Skills::Registry.reload!
      end

      after { FileUtils.remove_entry(tmp_dir) }

      it "assembles all active skills into the system prompt" do
        session.activate_skill("gh-issue")
        session.activate_skill("testing")

        prompt = session.assemble_system_prompt
        expect(prompt).to include("### GitHub Issue Writing")
        expect(prompt).to include("### Testing Guide")
      end

      it "preserves activation order" do
        session.activate_skill("testing")
        session.activate_skill("gh-issue")

        expect(session.reload.active_skills).to eq(%w[testing gh-issue])
      end

      it "deactivates one skill while others remain active" do
        session.activate_skill("gh-issue")
        session.activate_skill("testing")
        session.deactivate_skill("gh-issue")

        expect(session.reload.active_skills).to eq(["testing"])
        prompt = session.assemble_system_prompt
        expect(prompt).to include("### Testing Guide")
        expect(prompt).not_to include("GitHub Issue Writing")
      end
    end
  end

  describe "#messages_for_llm" do
    let(:session) { Session.create! }

    it "returns user_message events with user role and timestamp prefix" do
      session.events.create!(event_type: "user_message", payload: {"content" => "hello"}, timestamp: 1)

      expect(session.messages_for_llm).to eq([{role: "user", content: timestamped("hello", 1)}])
    end

    it "returns agent_message events with assistant role" do
      session.events.create!(event_type: "agent_message", payload: {"content" => "hi there"}, timestamp: 1)

      expect(session.messages_for_llm).to eq([{role: "assistant", content: "hi there"}])
    end

    it "includes system_message events as user role with [system] prefix" do
      session.events.create!(event_type: "system_message", payload: {"content" => "MCP: server failed"}, timestamp: 1)

      messages = session.messages_for_llm
      expect(messages.size).to eq(1)
      expect(messages.first[:role]).to eq("user")
      expect(messages.first[:content]).to eq("[system] MCP: server failed")
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
          {role: "user", content: timestamped("what is on example.com?", 1)},
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
        {role: "user", content: timestamped("first", 1)},
        {role: "assistant", content: "second"},
        {role: "user", content: timestamped("third", 3)}
      ])
    end

    context "with token budget" do
      it "includes all events when within budget" do
        session.events.create!(event_type: "user_message", payload: {"content" => "hi"}, timestamp: 1, token_count: 10)
        session.events.create!(event_type: "agent_message", payload: {"content" => "hello"}, timestamp: 2, token_count: 10)

        expect(session.messages_for_llm(token_budget: 100)).to eq([
          {role: "user", content: timestamped("hi", 1)},
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
          {role: "user", content: timestamped("recent", 3)},
          {role: "assistant", content: "recent reply"}
        ])
      end

      it "always includes at least the newest event even if it exceeds budget" do
        session.events.create!(event_type: "user_message", payload: {"content" => "big message"}, timestamp: 1, token_count: 500)

        result = session.messages_for_llm(token_budget: 100)

        expect(result).to eq([{role: "user", content: timestamped("big message", 1)}])
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

        expect(result.map { |m| m[:content] }).to eq([timestamped("first", 1), "second", timestamped("third", 3)])
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
      expect(result).to eq([{role: "user", content: timestamped("delivered", 1)}])
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

  describe "#recalculate_viewport!" do
    let(:session) { Session.create! }

    it "returns empty array when viewport has not changed" do
      event = session.events.create!(event_type: "user_message", payload: {"content" => "hi"}, timestamp: 1, token_count: 10)
      session.snapshot_viewport!([event.id])

      expect(session.recalculate_viewport!).to eq([])
    end

    it "returns evicted event IDs when viewport shrinks" do
      old = session.events.create!(event_type: "user_message", payload: {"content" => "old"}, timestamp: 1, token_count: 100_000)
      new_event = session.events.create!(event_type: "agent_message", payload: {"content" => "new"}, timestamp: 2, token_count: 100_000)
      session.update_column(:viewport_event_ids, [old.id, new_event.id])

      # Add a large event that pushes 'old' out of the viewport
      session.events.create!(event_type: "user_message", payload: {"content" => "big"}, timestamp: 3, token_count: 100_000)

      evicted = session.recalculate_viewport!
      expect(evicted).to include(old.id)
    end

    it "updates the stored viewport snapshot" do
      event = session.events.create!(event_type: "user_message", payload: {"content" => "hi"}, timestamp: 1, token_count: 10)
      session.recalculate_viewport!

      expect(session.reload.viewport_event_ids).to eq([event.id])
    end

    it "does not write to the database when viewport is unchanged" do
      event = session.events.create!(event_type: "user_message", payload: {"content" => "hi"}, timestamp: 1, token_count: 10)
      session.snapshot_viewport!([event.id])

      expect(session).not_to receive(:update_column)
      session.recalculate_viewport!
    end
  end

  describe "#snapshot_viewport!" do
    let(:session) { Session.create! }

    it "stores the given event IDs" do
      session.snapshot_viewport!([1, 2, 3])
      expect(session.reload.viewport_event_ids).to eq([1, 2, 3])
    end

    it "overwrites previous snapshot" do
      session.snapshot_viewport!([1, 2])
      session.snapshot_viewport!([3, 4, 5])
      expect(session.reload.viewport_event_ids).to eq([3, 4, 5])
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
