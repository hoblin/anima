# frozen_string_literal: true

require "rails_helper"

RSpec.describe SessionChannel, type: :channel do
  let(:session_id) { 42 }
  let(:stream_name) { "session_#{session_id}" }

  describe "#subscribed" do
    it "streams from the session-specific stream" do
      subscribe(session_id: session_id)

      expect(subscription).to be_confirmed
      expect(subscription).to have_stream_from(stream_name)
    end

    it "works with string session_id" do
      subscribe(session_id: "7")

      expect(subscription).to be_confirmed
      expect(subscription).to have_stream_from("session_7")
    end

    it "rejects subscription without session_id" do
      subscribe(session_id: nil)

      expect(subscription).to be_rejected
    end

    it "rejects subscription with non-numeric session_id" do
      subscribe(session_id: "abc")

      expect(subscription).to be_rejected
    end

    it "rejects subscription with zero session_id" do
      subscribe(session_id: 0)

      expect(subscription).to be_rejected
    end

    it "transmits chat history including tool events for existing session" do
      session = Session.create!(id: session_id)
      session.events.create!(event_type: "user_message", payload: {"type" => "user_message", "content" => "hello"}, timestamp: 1)
      session.events.create!(event_type: "agent_message", payload: {"type" => "agent_message", "content" => "hi there"}, timestamp: 2)
      session.events.create!(event_type: "tool_call", payload: {"type" => "tool_call", "content" => "calling bash"}, timestamp: 3)

      subscribe(session_id: session_id)

      history = transmissions.reject { |t| t["action"] == "view_mode" }
      expect(history.size).to eq(3)
      expect(history[0]).to include("type" => "user_message", "content" => "hello")
      expect(history[1]).to include("type" => "agent_message", "content" => "hi there")
      expect(history[2]).to include("type" => "tool_call", "content" => "calling bash")
    end

    it "includes structured rendered output in history transmissions" do
      session = Session.create!(id: session_id)
      session.events.create!(event_type: "user_message", payload: {"type" => "user_message", "content" => "hello"}, timestamp: 1)
      session.events.create!(event_type: "agent_message", payload: {"type" => "agent_message", "content" => "hi"}, timestamp: 2)
      session.events.create!(event_type: "tool_call", payload: {"type" => "tool_call", "content" => "calling bash"}, timestamp: 3)

      subscribe(session_id: session_id)

      # First transmission is view_mode, then history
      view_mode_msg = transmissions.find { |t| t["action"] == "view_mode" }
      expect(view_mode_msg["view_mode"]).to eq("basic")

      history = transmissions.reject { |t| t["action"] == "view_mode" }
      expect(history[0]["rendered"]).to eq("basic" => {"role" => :user, "content" => "hello"})
      expect(history[1]["rendered"]).to eq("basic" => {"role" => :assistant, "content" => "hi"})
      expect(history[2]["rendered"]).to eq("basic" => nil)
    end

    it "transmits view_mode on subscription" do
      Session.create!(id: session_id)

      subscribe(session_id: session_id)

      view_mode_msg = transmissions.find { |t| t["action"] == "view_mode" }
      expect(view_mode_msg).to be_present
      expect(view_mode_msg["view_mode"]).to eq("basic")
    end

    it "decorates history in the session's view_mode" do
      session = Session.create!(id: session_id, view_mode: "verbose")
      session.events.create!(event_type: "user_message", payload: {"type" => "user_message", "content" => "hello"}, timestamp: 1)

      subscribe(session_id: session_id)

      history = transmissions.reject { |t| t["action"] == "view_mode" }
      expect(history[0]["rendered"]).to eq("verbose" => {"role" => :user, "content" => "hello", "timestamp" => 1})
    end

    it "excludes system_message events from history" do
      session = Session.create!(id: session_id)
      session.events.create!(event_type: "user_message", payload: {"type" => "user_message", "content" => "hello"}, timestamp: 1)
      session.events.create!(event_type: "system_message", payload: {"type" => "system_message", "content" => "internal"}, timestamp: 2)

      subscribe(session_id: session_id)

      history = transmissions.reject { |t| t["action"] == "view_mode" }
      expect(history.size).to eq(1)
      expect(history[0]).to include("type" => "user_message")
    end

    it "transmits only view_mode for a session with no messages" do
      Session.create!(id: session_id)

      subscribe(session_id: session_id)

      expect(transmissions.size).to eq(1)
      expect(transmissions[0]["action"]).to eq("view_mode")
    end
  end

  describe "#receive" do
    it "broadcasts the received data to the session stream" do
      subscribe(session_id: session_id)
      data = {"type" => "user_message", "content" => "hello"}

      expect { perform(:receive, data) }
        .to have_broadcasted_to(stream_name).with(hash_including(data))
    end
  end

  describe "#speak" do
    let!(:session) { Session.create!(id: session_id) }

    before { subscribe(session_id: session_id) }

    it "emits a user_message event on the EventBus" do
      emitted = []
      subscriber = double("subscriber")
      allow(subscriber).to receive(:emit) { |event| emitted << event }
      Events::Bus.subscribe(subscriber)

      perform(:speak, {"content" => "hello brain"})

      user_event = emitted.find { |e| e.dig(:payload, :type) == "user_message" }
      expect(user_event).to be_present
      expect(user_event.dig(:payload, :content)).to eq("hello brain")
      expect(user_event.dig(:payload, :session_id)).to eq(session_id)

      Events::Bus.unsubscribe(subscriber)
    end

    it "enqueues an AgentRequestJob" do
      expect { perform(:speak, {"content" => "process this"}) }
        .to have_enqueued_job(AgentRequestJob).with(session_id)
    end

    it "ignores empty content" do
      expect { perform(:speak, {"content" => "  "}) }
        .not_to have_enqueued_job(AgentRequestJob)
    end

    it "ignores nil content" do
      expect { perform(:speak, {"content" => nil}) }
        .not_to have_enqueued_job(AgentRequestJob)
    end

    it "strips whitespace from content" do
      emitted = []
      subscriber = double("subscriber")
      allow(subscriber).to receive(:emit) { |event| emitted << event }
      Events::Bus.subscribe(subscriber)

      perform(:speak, {"content" => "  hello  "})

      user_event = emitted.find { |e| e.dig(:payload, :type) == "user_message" }
      expect(user_event.dig(:payload, :content)).to eq("hello")

      Events::Bus.unsubscribe(subscriber)
    end
  end

  describe "#list_sessions" do
    before do
      subscribe(session_id: session_id)
    end

    it "returns recent sessions with metadata" do
      s1 = Session.create!
      s1.events.create!(event_type: "user_message", payload: {"type" => "user_message", "content" => "hi"}, timestamp: 1)
      s1.events.create!(event_type: "agent_message", payload: {"type" => "agent_message", "content" => "hello"}, timestamp: 2)
      s2 = Session.create!

      perform(:list_sessions, {"limit" => 10})

      response = transmissions.last
      expect(response["action"]).to eq("sessions_list")

      sessions = response["sessions"]
      expect(sessions.size).to eq(2)

      newest = sessions.first
      expect(newest["id"]).to eq(s2.id)
      expect(newest["message_count"]).to eq(0)

      oldest = sessions.last
      expect(oldest["id"]).to eq(s1.id)
      expect(oldest["message_count"]).to eq(2)
    end

    it "respects the limit parameter" do
      3.times { Session.create! }

      perform(:list_sessions, {"limit" => 2})

      response = transmissions.last
      expect(response["sessions"].size).to eq(2)
    end

    it "defaults to 10 sessions" do
      12.times { Session.create! }

      perform(:list_sessions, {})

      response = transmissions.last
      expect(response["sessions"].size).to eq(10)
    end

    it "clamps limit to 50" do
      55.times { Session.create! }

      perform(:list_sessions, {"limit" => 100})

      response = transmissions.last
      expect(response["action"]).to eq("sessions_list")
      expect(response["sessions"].size).to eq(50)
    end

    it "returns empty list when no sessions exist" do
      perform(:list_sessions, {})

      response = transmissions.last
      expect(response["action"]).to eq("sessions_list")
      expect(response["sessions"]).to eq([])
    end
  end

  describe "#create_session" do
    before do
      Session.create!(id: session_id)
      subscribe(session_id: session_id)
    end

    it "creates a new session" do
      expect { perform(:create_session, {}) }.to change(Session, :count).by(1)
    end

    it "transmits session_changed with the new session ID" do
      perform(:create_session, {})

      changed = transmissions.find { |t| t["action"] == "session_changed" }
      expect(changed).to be_present
      expect(changed["session_id"]).to eq(Session.last.id)
      expect(changed["message_count"]).to eq(0)
    end

    it "switches the stream to the new session" do
      perform(:create_session, {})

      new_session = Session.last
      expect(subscription).to have_stream_from("session_#{new_session.id}")
    end
  end

  describe "#switch_session" do
    let!(:source_session) { Session.create!(id: session_id) }
    let!(:target_session) { Session.create! }

    before do
      target_session.events.create!(event_type: "user_message", payload: {"type" => "user_message", "content" => "old msg"}, timestamp: 1)
      target_session.events.create!(event_type: "agent_message", payload: {"type" => "agent_message", "content" => "old reply"}, timestamp: 2)
      subscribe(session_id: session_id)
    end

    it "transmits session_changed with the target session info including view_mode" do
      perform(:switch_session, {"session_id" => target_session.id})

      changed = transmissions.find { |t| t["action"] == "session_changed" }
      expect(changed["session_id"]).to eq(target_session.id)
      expect(changed["message_count"]).to eq(2)
      expect(changed["view_mode"]).to eq("basic")
    end

    it "transmits chat history from the target session" do
      perform(:switch_session, {"session_id" => target_session.id})

      history = transmissions.select { |t| t["type"].in?(%w[user_message agent_message]) }
      expect(history.size).to eq(2)
      expect(history[0]["content"]).to eq("old msg")
      expect(history[1]["content"]).to eq("old reply")
    end

    it "switches the stream to the target session" do
      perform(:switch_session, {"session_id" => target_session.id})

      expect(subscription).to have_stream_from("session_#{target_session.id}")
    end

    it "transmits error for non-existent session" do
      perform(:switch_session, {"session_id" => 999_999})

      error = transmissions.find { |t| t["action"] == "error" }
      expect(error).to be_present
      expect(error["message"]).to eq("Session not found")
    end

    it "transmits error for zero session ID" do
      perform(:switch_session, {"session_id" => 0})

      error = transmissions.find { |t| t["action"] == "error" }
      expect(error).to be_present
    end

    it "transmits error for negative session ID" do
      perform(:switch_session, {"session_id" => -1})

      error = transmissions.find { |t| t["action"] == "error" }
      expect(error).to be_present
      expect(error["message"]).to eq("Session not found")
    end
  end

  describe "#change_view_mode" do
    let!(:session) { Session.create!(id: session_id) }

    before do
      session.events.create!(event_type: "user_message", payload: {"type" => "user_message", "content" => "hello"}, timestamp: 1)
      session.events.create!(event_type: "agent_message", payload: {"type" => "agent_message", "content" => "hi"}, timestamp: 2)
      subscribe(session_id: session_id)
    end

    it "updates session view_mode" do
      perform(:change_view_mode, {"view_mode" => "verbose"})

      expect(session.reload.view_mode).to eq("verbose")
    end

    it "broadcasts view_mode_changed to all clients" do
      expect {
        perform(:change_view_mode, {"view_mode" => "verbose"})
      }.to have_broadcasted_to(stream_name)
        .with(a_hash_including("action" => "view_mode_changed", "view_mode" => "verbose"))
    end

    it "broadcasts re-decorated viewport events" do
      expect {
        perform(:change_view_mode, {"view_mode" => "verbose"})
      }.to have_broadcasted_to(stream_name)
        .with(a_hash_including("rendered" => {"verbose" => a_hash_including("role" => "user", "content" => "hello", "timestamp" => 1)}))
    end

    it "transmits error for invalid view mode" do
      perform(:change_view_mode, {"view_mode" => "fancy"})

      error = transmissions.find { |t| t["action"] == "error" }
      expect(error).to be_present
      expect(error["message"]).to eq("Invalid view mode")
    end

    it "transmits error for nil view mode" do
      perform(:change_view_mode, {"view_mode" => nil})

      error = transmissions.find { |t| t["action"] == "error" }
      expect(error).to be_present
    end
  end

  describe "stream isolation" do
    it "does not broadcast to other sessions" do
      subscribe(session_id: session_id)
      data = {"type" => "user_message", "content" => "hello"}

      expect { perform(:receive, data) }
        .not_to have_broadcasted_to("session_99")
    end
  end
end
