# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Mneme terminal event trigger integration" do
  let(:session) { Session.create! }

  before do
    allow(Anima::Settings).to receive(:mneme_viewport_fraction).and_return(0.33)
    allow(Anima::Settings).to receive(:mneme_max_tokens).and_return(2048)
    allow(Anima::Settings).to receive(:fast_model).and_return("claude-haiku-4-5")
  end

  # Helper to create events with predetermined token counts.
  def create_event(type:, content: "msg", token_count: 100, tool_name: nil, tool_input: nil)
    payload = case type
    when "tool_call"
      {"content" => "Calling #{tool_name}", "tool_name" => tool_name,
       "tool_input" => tool_input || {}, "tool_use_id" => "tu_#{SecureRandom.hex(4)}"}
    when "tool_response"
      {"content" => content, "tool_name" => tool_name, "tool_use_id" => "tu_#{SecureRandom.hex(4)}"}
    else
      {"content" => content}
    end

    session.events.create!(
      event_type: type,
      payload: payload,
      tool_use_id: payload["tool_use_id"],
      timestamp: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond),
      token_count: token_count
    )
  end

  describe "filling viewport triggers Mneme" do
    # Use a small token budget so we can fill the viewport with few events.
    # Each event is 1000 tokens, budget is 3000 tokens → viewport holds 3 events.
    let(:budget) { 3000 }
    let(:event_size) { 1000 }

    before do
      allow(Anima::Settings).to receive(:token_budget).and_return(budget)
    end

    it "initializes boundary on first event, triggers when it evicts" do
      # Step 1: Create first event — boundary should be initialized
      first = create_event(type: "user_message", content: "first message", token_count: event_size)
      session.recalculate_viewport!
      session.schedule_mneme!
      expect(session.reload.mneme_boundary_event_id).to eq(first.id)

      # Step 2: Fill viewport (3 events fit in budget)
      create_event(type: "agent_message", content: "reply 1", token_count: event_size)
      create_event(type: "user_message", content: "question 2", token_count: event_size)
      session.recalculate_viewport!
      session.schedule_mneme!
      # Boundary still in viewport — no job
      expect(session.reload.mneme_boundary_event_id).to eq(first.id)

      # Step 3: Add one more event — pushes first event out of viewport
      create_event(type: "agent_message", content: "reply 2", token_count: event_size)
      session.recalculate_viewport!

      # Boundary event is no longer in viewport
      expect(session.viewport_event_ids).not_to include(first.id)

      # Mneme should be triggered
      expect { session.schedule_mneme! }.to have_enqueued_job(MnemeJob).with(session.id)
    end
  end

  describe "Mneme runner creates snapshot and advances boundary" do
    let(:client) { instance_double(LLM::Client) }

    it "creates a snapshot and advances boundary through full cycle" do
      # Create conversation events
      first = create_event(type: "user_message", content: "Implement auth flow")
      create_event(type: "agent_message", content: "I'll start with OAuth")
      create_event(type: "user_message", content: "Use PKCE")
      last = create_event(type: "agent_message", content: "Done with PKCE implementation")

      session.update_column(:mneme_boundary_event_id, first.id)

      # Mock LLM to call save_snapshot
      allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
        registry = opts[:registry]
        registry.execute("save_snapshot", {"text" => "Discussed OAuth auth flow with PKCE."})
        "Done"
      }

      runner = Mneme::Runner.new(session, client: client)
      runner.call

      # Snapshot was created
      expect(Snapshot.count).to eq(1)
      snapshot = Snapshot.last
      expect(snapshot.text).to eq("Discussed OAuth auth flow with PKCE.")
      expect(snapshot.session).to eq(session)
      expect(snapshot.level).to eq(1)

      # Boundary was advanced past the old boundary
      session.reload
      expect(session.mneme_boundary_event_id).to eq(last.id)
      expect(session.mneme_snapshot_last_event_id).to eq(last.id)
    end
  end

  describe "cycle repeats" do
    let(:client) { instance_double(LLM::Client) }
    let(:budget) { 2000 }
    let(:event_size) { 500 }

    before do
      allow(Anima::Settings).to receive(:token_budget).and_return(budget)
    end

    it "fires Mneme again when the new boundary leaves viewport" do
      # Fill viewport: budget=2000, each event 500 tokens → holds 4 events.
      first = create_event(type: "user_message", content: "msg 1", token_count: event_size)
      create_event(type: "agent_message", content: "msg 2", token_count: event_size)
      create_event(type: "user_message", content: "msg 3", token_count: event_size)
      create_event(type: "agent_message", content: "msg 4", token_count: event_size)

      session.update_column(:mneme_boundary_event_id, first.id)
      session.recalculate_viewport!

      # 5th event pushes first out of viewport
      create_event(type: "user_message", content: "msg 5", token_count: event_size)
      session.recalculate_viewport!

      # First Mneme run — creates snapshot and advances boundary
      allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
        opts[:registry].execute("save_snapshot", {"text" => "First summary"})
        "Done"
      }

      runner = Mneme::Runner.new(session, client: client)
      runner.call

      new_boundary = session.reload.mneme_boundary_event_id
      expect(new_boundary).to be > first.id

      # Add enough events to guarantee the new boundary evicts.
      # Budget holds 4 events; we need 4 new events beyond the boundary.
      4.times do |i|
        type = i.even? ? "agent_message" : "user_message"
        create_event(type: type, content: "msg #{6 + i}", token_count: event_size)
      end
      session.recalculate_viewport!

      # New boundary must have left viewport — unconditional assertion
      expect(session.viewport_event_ids).not_to include(new_boundary)
      expect { session.schedule_mneme! }.to have_enqueued_job(MnemeJob).with(session.id)

      expect(Snapshot.count).to eq(1)
    end
  end

  describe "snapshots in viewport" do
    let(:client) { instance_double(LLM::Client) }

    before do
      allow(Anima::Settings).to receive(:token_budget).and_return(10_000)
      allow(Anima::Settings).to receive(:mneme_l1_budget_fraction).and_return(0.15)
      allow(Anima::Settings).to receive(:mneme_l2_budget_fraction).and_return(0.05)
    end

    it "snapshot appears in messages_for_llm after source events evict" do
      # Create events and a snapshot covering them
      e1 = create_event(type: "user_message", content: "old conversation", token_count: 100)
      e2 = create_event(type: "agent_message", content: "old reply", token_count: 100)

      session.snapshots.create!(
        text: "Discussed old topic", from_event_id: e1.id, to_event_id: e2.id, level: 1, token_count: 50
      )

      # While source events are in viewport — snapshot should NOT appear
      messages_with_source = session.messages_for_llm(token_budget: 10_000)
      snapshot_messages = messages_with_source.select { |m| m[:content].to_s.include?("[recent memory]") }
      expect(snapshot_messages).to be_empty

      # Add events that push old ones out (reduce budget so old events evict)
      3.times { |i| create_event(type: "user_message", content: "new #{i}", token_count: 3000) }

      # Now snapshot should appear (source events evicted)
      messages_after_eviction = session.messages_for_llm(token_budget: 10_000)
      snapshot_messages = messages_after_eviction.select { |m| m[:content].to_s.include?("[recent memory]") }
      expect(snapshot_messages.size).to eq(1)
      expect(snapshot_messages.first[:content]).to include("Discussed old topic")
    end
  end

  describe "L2 compression cycle" do
    let(:client) { instance_double(LLM::Client) }

    before do
      allow(Anima::Settings).to receive(:token_budget).and_return(10_000)
      allow(Anima::Settings).to receive(:mneme_l1_budget_fraction).and_return(0.15)
      allow(Anima::Settings).to receive(:mneme_l2_budget_fraction).and_return(0.05)
      allow(Anima::Settings).to receive(:mneme_l2_snapshot_threshold).and_return(3)
    end

    it "L2 compression replaces L1 snapshots in viewport" do
      # Create old events (will evict) then a recent one that fills the sliding window
      e1 = create_event(type: "user_message", content: "old 1", token_count: 500)
      e2 = create_event(type: "agent_message", content: "old 2", token_count: 500)
      e3 = create_event(type: "user_message", content: "old 3", token_count: 500)
      e4 = create_event(type: "agent_message", content: "old 4", token_count: 500)
      e5 = create_event(type: "user_message", content: "old 5", token_count: 500)
      e6 = create_event(type: "agent_message", content: "old 6", token_count: 500)
      # Recent event large enough to fill the entire sliding window (800 tokens after fractions)
      create_event(type: "user_message", content: "recent", token_count: 750)

      # L1 snapshots with contiguous ranges covering old events
      session.snapshots.create!(text: "L1 first", from_event_id: e1.id, to_event_id: e2.id, level: 1, token_count: 50)
      session.snapshots.create!(text: "L1 second", from_event_id: e3.id, to_event_id: e4.id, level: 1, token_count: 50)
      session.snapshots.create!(text: "L1 third", from_event_id: e5.id, to_event_id: e6.id, level: 1, token_count: 50)

      # Budget tight so old events evict, making snapshots visible
      messages_before = session.messages_for_llm(token_budget: 1000)
      l1_messages = messages_before.select { |m| m[:content].to_s.include?("[recent memory]") }
      expect(l1_messages.size).to eq(3)

      # Run L2 compression
      allow(client).to receive(:chat_with_tools) { |_msgs, **opts|
        opts[:registry].execute("save_snapshot", {"text" => "L2 meta-summary of all three"})
        "Done"
      }
      Mneme::L2Runner.new(session, client: client).call

      # After L2: L1s replaced by one L2
      messages_after = session.messages_for_llm(token_budget: 1000)
      l1_messages = messages_after.select { |m| m[:content].to_s.include?("[recent memory]") }
      l2_messages = messages_after.select { |m| m[:content].to_s.include?("[long-term memory]") }

      expect(l1_messages).to be_empty
      expect(l2_messages.size).to eq(1)
      expect(l2_messages.first[:content]).to include("L2 meta-summary of all three")
    end
  end
end
