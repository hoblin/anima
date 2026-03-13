# frozen_string_literal: true

require "rails_helper"

RSpec.describe Event::Broadcasting do
  let(:session) { Session.create! }

  def create_event(attrs = {})
    session.events.create!({
      event_type: "user_message",
      payload: {"type" => "user_message", "content" => "hello", "session_id" => session.id},
      timestamp: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
    }.merge(attrs))
  end

  describe "after_create_commit" do
    it "broadcasts the event to the session stream" do
      expect {
        create_event
      }.to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("action" => "create", "content" => "hello"))
    end

    it "includes the event database ID in the broadcast" do
      event = nil
      expect {
        event = create_event
      }.to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("id" => be_a(Integer), "action" => "create"))
    end

    it "decorates the payload with rendered data for the session view mode" do
      expect {
        create_event
      }.to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("rendered" => {"basic" => {"role" => "user", "content" => "hello"}}))
    end

    it "decorates using the session's current view mode" do
      session.update!(view_mode: "verbose")
      event = Events::UserMessage.new(content: "hello", session_id: session.id)

      expect {
        create_event
      }.to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("rendered" => {"verbose" => a_hash_including("role" => "user", "content" => "hello")}))
    end

    it "broadcasts tool_call events" do
      expect {
        session.events.create!(
          event_type: "tool_call",
          payload: {"type" => "tool_call", "content" => "calling bash", "tool_name" => "bash",
                    "tool_input" => {}, "session_id" => session.id},
          timestamp: 1
        )
      }.to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("action" => "create", "tool_name" => "bash"))
    end

    it "falls back to basic when session has default view mode" do
      expect {
        create_event
      }.to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("rendered" => {"basic" => a_hash_including("role" => "user")}))
    end
  end

  describe "after_update_commit" do
    it "broadcasts with action update when event is updated" do
      event = create_event

      expect {
        event.update!(token_count: 42)
      }.to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("id" => event.id, "action" => "update"))
    end

    it "re-decorates with current token count after update" do
      session.update!(view_mode: "debug")
      event = create_event

      expect {
        event.update!(token_count: 42)
      }.to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including(
          "action" => "update",
          "rendered" => {"debug" => a_hash_including("tokens" => 42, "estimated" => false)}
        ))
    end

    it "uses the session's current view mode for update broadcasts" do
      event = create_event
      session.update!(view_mode: "verbose")

      expect {
        event.update!(token_count: 10)
      }.to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including(
          "action" => "update",
          "rendered" => {"verbose" => a_hash_including("role" => "user")}
        ))
    end
  end
end
