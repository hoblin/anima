# frozen_string_literal: true

require "rails_helper"

RSpec.describe Session, "#schedule_mneme!" do
  let(:session) { Session.create! }

  # Helper to create events with predetermined token counts.
  def create_event(session, type:, content: "msg", token_count: 100, tool_name: nil, tool_input: nil)
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

  context "when session has no boundary event" do
    it "initializes the boundary to the first conversation event" do
      event = create_event(session, type: "user_message", content: "Hello")

      session.schedule_mneme!

      expect(session.reload.mneme_boundary_event_id).to eq(event.id)
    end

    it "skips tool_call events when finding the first conversation event" do
      create_event(session, type: "tool_call", tool_name: "bash")
      user_event = create_event(session, type: "user_message", content: "Hello")

      session.schedule_mneme!

      expect(session.reload.mneme_boundary_event_id).to eq(user_event.id)
    end

    it "does not enqueue MnemeJob on initialization" do
      create_event(session, type: "user_message", content: "Hello")

      expect { session.schedule_mneme! }.not_to have_enqueued_job(MnemeJob)
    end

    it "initializes the boundary to a think event when no messages exist" do
      think = create_event(session, type: "tool_call", tool_name: "think",
        tool_input: {"thoughts" => "Let me think"})

      session.schedule_mneme!

      expect(session.reload.mneme_boundary_event_id).to eq(think.id)
    end

    it "does nothing when there are no conversation events" do
      session.schedule_mneme!

      expect(session.reload.mneme_boundary_event_id).to be_nil
    end
  end

  context "when boundary event is still in viewport" do
    before do
      event = create_event(session, type: "user_message", content: "Hello")
      session.update_column(:mneme_boundary_event_id, event.id)
      session.update_column(:viewport_event_ids, [event.id])
    end

    it "does not enqueue MnemeJob" do
      expect { session.schedule_mneme! }.not_to have_enqueued_job(MnemeJob)
    end
  end

  context "when boundary event has left the viewport" do
    before do
      old_event = create_event(session, type: "user_message", content: "Old message")
      new_event = create_event(session, type: "user_message", content: "New message")
      session.update_column(:mneme_boundary_event_id, old_event.id)
      # Viewport only contains the new event (old one evicted)
      session.update_column(:viewport_event_ids, [new_event.id])
    end

    it "enqueues MnemeJob" do
      expect { session.schedule_mneme! }.to have_enqueued_job(MnemeJob).with(session.id)
    end
  end

  context "for sub-agent sessions" do
    it "does not schedule Mneme" do
      parent = Session.create!
      child = Session.create!(parent_session: parent)
      create_event(child, type: "user_message", content: "Hello")

      expect { child.schedule_mneme! }.not_to have_enqueued_job(MnemeJob)
    end
  end
end
