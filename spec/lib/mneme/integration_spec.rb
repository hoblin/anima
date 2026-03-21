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
end
