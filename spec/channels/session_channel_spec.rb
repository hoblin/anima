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

    context "without session_id (server-side resolution)" do
      it "resolves to the most recent session" do
        existing = Session.create!

        subscribe(session_id: nil)

        expect(subscription).to be_confirmed
        expect(subscription).to have_stream_from("session_#{existing.id}")
      end

      it "creates a session when none exist" do
        expect { subscribe(session_id: nil) }.to change(Session, :count).by(1)

        expect(subscription).to be_confirmed
      end

      it "transmits session_changed with the resolved session info" do
        existing = Session.create!
        existing.events.create!(event_type: "user_message", payload: {"type" => "user_message", "content" => "hi"}, timestamp: 1)

        subscribe(session_id: nil)

        changed = transmissions.find { |t| t["action"] == "session_changed" }
        expect(changed["session_id"]).to eq(existing.id)
        expect(changed["message_count"]).to eq(1)
        expect(changed["view_mode"]).to eq("basic")
      end
    end

    context "with session_id of zero" do
      it "resolves to the most recent session" do
        existing = Session.create!

        subscribe(session_id: 0)

        expect(subscription).to be_confirmed
        expect(subscription).to have_stream_from("session_#{existing.id}")
      end
    end

    it "transmits session_changed on subscription" do
      session = Session.create!(id: session_id)
      session.events.create!(event_type: "user_message", payload: {"type" => "user_message", "content" => "hello"}, timestamp: 1)

      subscribe(session_id: session_id)

      changed = transmissions.find { |t| t["action"] == "session_changed" }
      expect(changed).to be_present
      expect(changed["session_id"]).to eq(session_id)
      expect(changed["parent_session_id"]).to be_nil
      expect(changed["message_count"]).to eq(1)
      expect(changed["view_mode"]).to eq("basic")
    end

    it "includes name in session_changed" do
      Session.create!(id: session_id, name: "🔧 Debug Session")

      subscribe(session_id: session_id)

      changed = transmissions.find { |t| t["action"] == "session_changed" }
      expect(changed["name"]).to eq("🔧 Debug Session")
    end

    it "includes nil name in session_changed for unnamed sessions" do
      Session.create!(id: session_id)

      subscribe(session_id: session_id)

      changed = transmissions.find { |t| t["action"] == "session_changed" }
      expect(changed["name"]).to be_nil
    end

    it "includes active_skills in session_changed" do
      Session.create!(id: session_id, active_skills: ["gh-issue", "activerecord"])

      subscribe(session_id: session_id)

      changed = transmissions.find { |t| t["action"] == "session_changed" }
      expect(changed["active_skills"]).to eq(["gh-issue", "activerecord"])
    end

    it "includes empty active_skills for sessions with no skills" do
      Session.create!(id: session_id)

      subscribe(session_id: session_id)

      changed = transmissions.find { |t| t["action"] == "session_changed" }
      expect(changed["active_skills"]).to eq([])
    end

    it "includes active_workflow in session_changed" do
      Session.create!(id: session_id, active_workflow: "feature")

      subscribe(session_id: session_id)

      changed = transmissions.find { |t| t["action"] == "session_changed" }
      expect(changed["active_workflow"]).to eq("feature")
    end

    it "includes nil active_workflow for sessions with no workflow" do
      Session.create!(id: session_id)

      subscribe(session_id: session_id)

      changed = transmissions.find { |t| t["action"] == "session_changed" }
      expect(changed["active_workflow"]).to be_nil
    end

    it "includes goals in session_changed" do
      session = Session.create!(id: session_id)
      Goal.create!(session: session, description: "Test goal")

      subscribe(session_id: session_id)

      changed = transmissions.find { |t| t["action"] == "session_changed" }
      expect(changed["goals"]).to be_an(Array)
      expect(changed["goals"].size).to eq(1)
      expect(changed["goals"].first["description"]).to eq("Test goal")
    end

    it "includes empty goals for sessions with no goals" do
      Session.create!(id: session_id)

      subscribe(session_id: session_id)

      changed = transmissions.find { |t| t["action"] == "session_changed" }
      expect(changed["goals"]).to eq([])
    end

    it "includes parent_session_id for child sessions" do
      parent = Session.create!
      child = Session.create!(parent_session: parent)

      subscribe(session_id: child.id)

      changed = transmissions.find { |t| t["action"] == "session_changed" }
      expect(changed["parent_session_id"]).to eq(parent.id)
    end

    it "includes children in session_changed for parent sessions" do
      parent = Session.create!(id: session_id)
      child = Session.create!(parent_session: parent, prompt: "task", name: "analyzer", processing: true)

      subscribe(session_id: session_id)

      changed = transmissions.find { |t| t["action"] == "session_changed" }
      expect(changed["children"]).to eq([
        {"id" => child.id, "name" => "analyzer", "processing" => true}
      ])
    end

    it "omits children key when session has no children" do
      Session.create!(id: session_id)

      subscribe(session_id: session_id)

      changed = transmissions.find { |t| t["action"] == "session_changed" }
      expect(changed).not_to have_key("children")
    end

    it "snapshots viewport event IDs on subscription" do
      session = Session.create!(id: session_id)
      e1 = session.events.create!(event_type: "user_message", payload: {"type" => "user_message", "content" => "hello"}, timestamp: 1)
      e2 = session.events.create!(event_type: "agent_message", payload: {"type" => "agent_message", "content" => "hi"}, timestamp: 2)

      subscribe(session_id: session_id)

      expect(session.reload.viewport_event_ids).to eq([e1.id, e2.id])
    end

    it "transmits chat history including tool events for existing session" do
      session = Session.create!(id: session_id)
      session.events.create!(event_type: "user_message", payload: {"type" => "user_message", "content" => "hello"}, timestamp: 1)
      session.events.create!(event_type: "agent_message", payload: {"type" => "agent_message", "content" => "hi there"}, timestamp: 2)
      session.events.create!(event_type: "tool_call", payload: {"type" => "tool_call", "content" => "calling bash"}, tool_use_id: "toolu_test1", timestamp: 3)

      subscribe(session_id: session_id)

      history = transmissions.reject { |t| t["action"] }
      expect(history.size).to eq(3)
      expect(history[0]).to include("type" => "user_message", "content" => "hello")
      expect(history[1]).to include("type" => "agent_message", "content" => "hi there")
      expect(history[2]).to include("type" => "tool_call", "content" => "calling bash")
    end

    it "includes structured rendered output in history transmissions" do
      session = Session.create!(id: session_id)
      session.events.create!(event_type: "user_message", payload: {"type" => "user_message", "content" => "hello"}, timestamp: 1)
      session.events.create!(event_type: "agent_message", payload: {"type" => "agent_message", "content" => "hi"}, timestamp: 2)
      session.events.create!(event_type: "tool_call", payload: {"type" => "tool_call", "content" => "calling bash"}, tool_use_id: "toolu_test2", timestamp: 3)

      subscribe(session_id: session_id)

      # First transmission is session_changed, then view_mode, then history
      view_mode_msg = transmissions.find { |t| t["action"] == "view_mode" }
      expect(view_mode_msg["view_mode"]).to eq("basic")

      history = transmissions.reject { |t| t["action"] }
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

      history = transmissions.reject { |t| t["action"] }
      expect(history[0]["rendered"]).to eq("verbose" => {"role" => :user, "content" => "hello", "timestamp" => 1})
    end

    it "includes system_message events in history" do
      session = Session.create!(id: session_id)
      session.events.create!(event_type: "user_message", payload: {"type" => "user_message", "content" => "hello"}, timestamp: 1)
      session.events.create!(event_type: "system_message", payload: {"type" => "system_message", "content" => "MCP: server failed"}, timestamp: 2)

      subscribe(session_id: session_id)

      history = transmissions.reject { |t| t["action"] }
      expect(history.size).to eq(2)
      types = history.map { |h| h["type"] }
      expect(types).to include("system_message")
    end

    it "transmits session_changed and view_mode for a session with no messages" do
      Session.create!(id: session_id)

      subscribe(session_id: session_id)

      actions = transmissions.select { |t| t["action"] }.map { |t| t["action"] }
      expect(actions).to eq(%w[session_changed view_mode])
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

    it "persists the user event immediately" do
      expect {
        perform(:speak, {"content" => "hello brain"})
      }.to change { session.events.where(event_type: "user_message").count }.by(1)

      event = session.events.last
      expect(event.payload["content"]).to eq("hello brain")
    end

    it "enqueues AgentRequestJob with event_id" do
      expect { perform(:speak, {"content" => "process this"}) }
        .to have_enqueued_job(AgentRequestJob)

      event = session.events.last
      expect(AgentRequestJob).to have_been_enqueued.with(session_id, event_id: event.id)
    end

    it "ignores empty content" do
      expect { perform(:speak, {"content" => "  "}) }
        .not_to change(Event, :count)
    end

    it "ignores nil content" do
      expect { perform(:speak, {"content" => nil}) }
        .not_to change(Event, :count)
    end

    it "strips whitespace from content" do
      perform(:speak, {"content" => "  hello  "})

      event = session.events.last
      expect(event.payload["content"]).to eq("hello")
    end

    context "when session is processing" do
      before { session.update!(processing: true) }

      it "emits a pending user_message event via EventBus" do
        emitted = []
        subscriber = double("subscriber")
        allow(subscriber).to receive(:emit) { |event| emitted << event }
        Events::Bus.subscribe(subscriber)

        perform(:speak, {"content" => "queued message"})

        user_event = emitted.find { |e| e.dig(:payload, :type) == "user_message" }
        expect(user_event.dig(:payload, :status)).to eq("pending")
        expect(user_event.dig(:payload, :session_id)).to eq(session.id)
      ensure
        Events::Bus.unsubscribe(subscriber)
      end

      it "does not enqueue AgentRequestJob" do
        expect { perform(:speak, {"content" => "queued"}) }
          .not_to have_enqueued_job(AgentRequestJob)
      end
    end
  end

  describe "#recall_pending" do
    let!(:session) { Session.create!(id: session_id) }

    before { subscribe(session_id: session_id) }

    it "deletes the pending event and broadcasts recall" do
      event = session.events.create!(
        event_type: "user_message",
        payload: {"type" => "user_message", "content" => "pending", "status" => "pending"},
        timestamp: 1,
        status: "pending"
      )

      expect {
        perform(:recall_pending, {"event_id" => event.id})
      }.to change(Event, :count).by(-1)
        .and have_broadcasted_to(stream_name)
        .with(a_hash_including("action" => "user_message_recalled", "event_id" => event.id))
    end

    it "ignores non-pending events" do
      event = session.events.create!(
        event_type: "user_message",
        payload: {"type" => "user_message", "content" => "delivered"},
        timestamp: 1
      )

      expect {
        perform(:recall_pending, {"event_id" => event.id})
      }.not_to change(Event, :count)
    end

    it "ignores events from other sessions" do
      other_session = Session.create!
      event = other_session.events.create!(
        event_type: "user_message",
        payload: {"type" => "user_message", "content" => "pending", "status" => "pending"},
        timestamp: 1,
        status: "pending"
      )

      expect {
        perform(:recall_pending, {"event_id" => event.id})
      }.not_to change(Event, :count)
    end

    it "ignores invalid event_id" do
      expect {
        perform(:recall_pending, {"event_id" => 0})
      }.not_to change(Event, :count)
    end
  end

  describe "#interrupt_execution" do
    let!(:session) { Session.create!(id: session_id) }

    before { subscribe(session_id: session_id) }

    context "when session is processing" do
      before { session.update!(processing: true) }

      it "sets interrupt_requested on the session" do
        perform(:interrupt_execution, {})

        expect(session.reload.interrupt_requested?).to be true
      end
    end

    context "when session is not processing" do
      it "does not set interrupt_requested" do
        perform(:interrupt_execution, {})

        expect(session.reload.interrupt_requested?).to be false
      end
    end

    context "when session does not exist" do
      before { session.destroy! }

      it "is a no-op" do
        expect { perform(:interrupt_execution, {}) }.not_to raise_error
      end
    end
  end

  describe "#list_sessions" do
    before do
      subscribe(session_id: session_id)
    end

    it "returns recent root sessions with metadata" do
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

    it "includes name for root sessions in the list" do
      named = Session.create!(name: "🧠 Brainstorm")
      unnamed = Session.create!

      perform(:list_sessions, {"limit" => 10})

      response = transmissions.last
      sessions = response["sessions"]

      named_entry = sessions.find { |s| s["id"] == named.id }
      unnamed_entry = sessions.find { |s| s["id"] == unnamed.id }

      expect(named_entry["name"]).to eq("🧠 Brainstorm")
      expect(unnamed_entry["name"]).to be_nil
    end

    it "excludes child sessions from the top level" do
      parent = Session.create!
      Session.create!(parent_session: parent, prompt: "sub-agent task")

      perform(:list_sessions, {"limit" => 10})

      response = transmissions.last
      ids = response["sessions"].map { |s| s["id"] }
      expect(ids).to include(parent.id)
      expect(ids.size).to eq(1)
    end

    it "nests child sessions under their parent" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "research", name: "codebase-analyzer")

      perform(:list_sessions, {"limit" => 10})

      response = transmissions.last
      parent_entry = response["sessions"].find { |s| s["id"] == parent.id }
      expect(parent_entry["children"]).to be_present
      expect(parent_entry["children"].size).to eq(1)

      child_entry = parent_entry["children"].first
      expect(child_entry["id"]).to eq(child.id)
      expect(child_entry["name"]).to eq("codebase-analyzer")
      expect(child_entry["processing"]).to eq(false)
    end

    it "sorts children by created_at" do
      parent = Session.create!
      older = Session.create!(parent_session: parent, prompt: "first", name: "alpha", created_at: 2.minutes.ago)
      newer = Session.create!(parent_session: parent, prompt: "second", name: "beta", created_at: 1.minute.ago)

      perform(:list_sessions, {"limit" => 10})

      response = transmissions.last
      children = response["sessions"].first["children"]
      expect(children.map { |c| c["id"] }).to eq([older.id, newer.id])
    end

    it "includes processing status for child sessions" do
      parent = Session.create!
      Session.create!(parent_session: parent, prompt: "task", processing: true)

      perform(:list_sessions, {"limit" => 10})

      response = transmissions.last
      child_entry = response["sessions"].first["children"].first
      expect(child_entry["processing"]).to eq(true)
    end

    it "includes message counts for child sessions" do
      parent = Session.create!
      child = Session.create!(parent_session: parent, prompt: "task")
      child.events.create!(event_type: "user_message", payload: {"type" => "user_message", "content" => "hi"}, timestamp: 1)
      child.events.create!(event_type: "agent_message", payload: {"type" => "agent_message", "content" => "ok"}, timestamp: 2)

      perform(:list_sessions, {"limit" => 10})

      response = transmissions.last
      child_entry = response["sessions"].first["children"].first
      expect(child_entry["message_count"]).to eq(2)
    end

    it "omits children key when session has no children" do
      Session.create!

      perform(:list_sessions, {"limit" => 10})

      response = transmissions.last
      expect(response["sessions"].first).not_to have_key("children")
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

      changed = transmissions.select { |t| t["action"] == "session_changed" }
      # First session_changed is from initial subscribe, second from create
      latest = changed.last
      expect(latest["session_id"]).to eq(Session.last.id)
      expect(latest["message_count"]).to eq(0)
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

      changed = transmissions.reverse.find { |t| t["action"] == "session_changed" }
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

    it "snapshots viewport on view mode change" do
      perform(:change_view_mode, {"view_mode" => "verbose"})

      event_ids = session.events.pluck(:id)
      expect(session.reload.viewport_event_ids).to eq(event_ids)
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

  describe "#save_token" do
    before { subscribe(session_id: session_id) }

    let(:valid_token) { "sk-ant-oat01-#{"a" * 67}" }

    context "with valid token" do
      before do
        allow(Providers::Anthropic).to receive(:validate_token_format!)
        allow(Providers::Anthropic).to receive(:validate_token_api!)
        allow(CredentialStore).to receive(:write)
      end

      it "saves the token and transmits token_saved without warning" do
        perform(:save_token, {"token" => valid_token})

        saved = transmissions.find { |t| t["action"] == "token_saved" }
        expect(saved).to be_present
        expect(saved).not_to have_key("warning")
        expect(CredentialStore).to have_received(:write)
          .with("anthropic", "subscription_token" => valid_token)
      end
    end

    context "with invalid format" do
      it "transmits token_error for wrong prefix" do
        perform(:save_token, {"token" => "sk-ant-api03-#{"a" * 67}"})

        error = transmissions.find { |t| t["action"] == "token_error" }
        expect(error).to be_present
        expect(error["message"]).to include("must start with")
      end

      it "transmits token_error for short token" do
        perform(:save_token, {"token" => "sk-ant-oat01-short"})

        error = transmissions.find { |t| t["action"] == "token_error" }
        expect(error).to be_present
        expect(error["message"]).to include("at least")
      end

      it "transmits token_error for empty token" do
        perform(:save_token, {"token" => ""})

        error = transmissions.find { |t| t["action"] == "token_error" }
        expect(error).to be_present
      end
    end

    context "with API validation failure" do
      before do
        allow(Providers::Anthropic).to receive(:validate_token_format!)
        allow(Providers::Anthropic).to receive(:validate_token_api!)
          .and_raise(Providers::Anthropic::AuthenticationError, "Token rejected by Anthropic API (401)")
      end

      it "transmits token_error" do
        perform(:save_token, {"token" => valid_token})

        error = transmissions.find { |t| t["action"] == "token_error" }
        expect(error).to be_present
        expect(error["message"]).to include("401")
      end
    end

    context "with transient API failure (server error, timeout, network)" do
      before do
        allow(Providers::Anthropic).to receive(:validate_token_format!)
        allow(CredentialStore).to receive(:write)
      end

      it "saves the token on ServerError and transmits token_saved with warning" do
        allow(Providers::Anthropic).to receive(:validate_token_api!)
          .and_raise(Providers::Anthropic::ServerError, "Anthropic server error (500): Internal Server Error")

        perform(:save_token, {"token" => valid_token})

        saved = transmissions.find { |t| t["action"] == "token_saved" }
        expect(saved).to be_present
        expect(saved["warning"]).to include("could not be verified")
        expect(CredentialStore).to have_received(:write)
          .with("anthropic", "subscription_token" => valid_token)
      end

      it "saves the token on RateLimitError and transmits token_saved with warning" do
        allow(Providers::Anthropic).to receive(:validate_token_api!)
          .and_raise(Providers::Anthropic::RateLimitError, "Rate limit exceeded")

        perform(:save_token, {"token" => valid_token})

        saved = transmissions.find { |t| t["action"] == "token_saved" }
        expect(saved).to be_present
        expect(saved["warning"]).to include("could not be verified")
      end

      it "saves the token on TransientError (network) and transmits token_saved with warning" do
        allow(Providers::Anthropic).to receive(:validate_token_api!)
          .and_raise(Providers::Anthropic::TransientError, "Errno::ECONNRESET: Connection reset by peer")

        perform(:save_token, {"token" => valid_token})

        saved = transmissions.find { |t| t["action"] == "token_saved" }
        expect(saved).to be_present
        expect(saved["warning"]).to include("could not be verified")
        expect(CredentialStore).to have_received(:write)
          .with("anthropic", "subscription_token" => valid_token)
      end

      it "does not transmit token_error on transient failures" do
        allow(Providers::Anthropic).to receive(:validate_token_api!)
          .and_raise(Providers::Anthropic::ServerError, "Anthropic server error (500)")

        perform(:save_token, {"token" => valid_token})

        error = transmissions.find { |t| t["action"] == "token_error" }
        expect(error).to be_nil
      end
    end
  end

  describe "debug mode system prompt" do
    let!(:session) { Session.create!(id: session_id, view_mode: "debug") }

    it "prepends system prompt in debug mode history when prompt exists" do
      allow_any_instance_of(Session).to receive(:system_prompt).and_return("You are Anima.")
      session.events.create!(event_type: "user_message", payload: {"type" => "user_message", "content" => "hi"}, timestamp: 1)

      subscribe(session_id: session_id)

      history = transmissions.reject { |t| t["action"] }
      system_prompt_msg = history.find { |t| t["type"] == "system_prompt" }

      expect(system_prompt_msg).to be_present
      expect(system_prompt_msg["rendered"]["debug"]["role"]).to eq(:system_prompt)
      expect(system_prompt_msg["rendered"]["debug"]["content"]).to eq("You are Anima.")
      expect(system_prompt_msg["rendered"]["debug"]["tokens"]).to be_positive
      expect(system_prompt_msg["rendered"]["debug"]["estimated"]).to be true
    end

    it "always prepends system prompt (soul is always present)" do
      session.events.create!(event_type: "user_message", payload: {"type" => "user_message", "content" => "hi"}, timestamp: 1)

      subscribe(session_id: session_id)

      history = transmissions.reject { |t| t["action"] }
      system_prompt_msg = history.find { |t| t["type"] == "system_prompt" }
      expect(system_prompt_msg).to be_present
      expect(system_prompt_msg["rendered"]["debug"]["content"]).to include("Soul")
    end

    it "does not prepend system prompt in basic mode" do
      session.update!(view_mode: "basic")
      allow_any_instance_of(Session).to receive(:system_prompt).and_return("You are Anima.")
      session.events.create!(event_type: "user_message", payload: {"type" => "user_message", "content" => "hi"}, timestamp: 1)

      subscribe(session_id: session_id)

      history = transmissions.reject { |t| t["action"] }
      system_prompt_msg = history.find { |t| t["type"] == "system_prompt" }
      expect(system_prompt_msg).to be_nil
    end

    it "broadcasts system prompt on view mode change to debug" do
      session.update!(view_mode: "basic")
      allow_any_instance_of(Session).to receive(:system_prompt).and_return("You are Anima.")
      session.events.create!(event_type: "user_message", payload: {"type" => "user_message", "content" => "hi"}, timestamp: 1)

      subscribe(session_id: session_id)

      expect {
        perform(:change_view_mode, {"view_mode" => "debug"})
      }.to have_broadcasted_to(stream_name)
        .with(a_hash_including(
          "type" => "system_prompt",
          "rendered" => {"debug" => a_hash_including(
            "role" => "system_prompt", "content" => "You are Anima.",
            "tokens" => a_value > 0, "estimated" => true
          )}
        ))
    end
  end

  describe "debug mode renders token counts" do
    let!(:session) { Session.create!(id: session_id, view_mode: "debug") }

    it "includes token info in debug-decorated user messages" do
      session.events.create!(
        event_type: "user_message",
        payload: {"type" => "user_message", "content" => "hello"},
        timestamp: 1,
        token_count: 5
      )

      subscribe(session_id: session_id)

      history = transmissions.reject { |t| t["action"] }
      msg = history.find { |t| t["type"] == "user_message" }
      rendered = msg.dig("rendered", "debug")

      expect(rendered["tokens"]).to eq(5)
      expect(rendered["estimated"]).to be false
    end

    it "includes tool_use_id in debug-decorated tool calls" do
      session.events.create!(
        event_type: "tool_call",
        payload: {
          "type" => "tool_call", "content" => "calling bash",
          "tool_name" => "bash", "tool_input" => {"command" => "ls"},
          "tool_use_id" => "toolu_abc"
        },
        timestamp: 1,
        tool_use_id: "toolu_abc"
      )

      subscribe(session_id: session_id)

      history = transmissions.reject { |t| t["action"] }
      msg = history.find { |t| t["type"] == "tool_call" }
      rendered = msg.dig("rendered", "debug")

      expect(rendered["tool_use_id"]).to eq("toolu_abc")
      expect(rendered["tool"]).to eq("bash")
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
