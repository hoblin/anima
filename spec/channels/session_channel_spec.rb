# frozen_string_literal: true

require "rails_helper"

RSpec.describe SessionChannel, type: :channel do
  let(:session_id) { 42 }
  let(:stream_name) { "session_#{session_id}" }

  describe "#subscribed" do
    it "confirms the subscription and streams from the session-specific name" do
      create(:session, id: session_id)

      subscribe(session_id: session_id)

      expect(subscription).to be_confirmed
      expect(subscription).to have_stream_from(stream_name)
    end

    context "without a usable session_id" do
      it "resolves nil to the most recent existing session" do
        existing = create(:session)

        subscribe(session_id: nil)

        expect(subscription).to have_stream_from("session_#{existing.id}")
      end

      it "resolves zero to the most recent existing session" do
        existing = create(:session)

        subscribe(session_id: 0)

        expect(subscription).to have_stream_from("session_#{existing.id}")
      end

      it "creates a session when none exist" do
        expect { subscribe(session_id: nil) }.to change(Session, :count).by(1)
        expect(subscription).to be_confirmed
      end
    end

    describe "session_changed payload" do
      context "for a fully populated root session" do
        let!(:session) { create(:session, id: session_id, name: "🔧 Debug Session") }
        let!(:child) { create(:session, :awaiting, parent_session: session, name: "analyzer") }

        before do
          Skills::Registry.reload!
          Workflows::Registry.reload!
          session.activate_skill("gh-issue")
          session.activate_workflow("feature")
          Goal.create!(session: session, description: "Test goal")
          create(:message, :user_message, session: session)

          subscribe(session_id: session_id)
        end

        it "serialises the full session metadata under one event" do
          changed = transmissions.find { |t| t["action"] == "session_changed" }

          expect(changed).to include(
            "session_id" => session_id,
            "name" => "🔧 Debug Session",
            "parent_session_id" => nil,
            "message_count" => 1,
            "view_mode" => "basic",
            "active_skills" => include("gh-issue"),
            "active_workflow" => "feature"
          )
          expect(changed["goals"].map { |g| g["description"] }).to include("Test goal")
          expect(changed["children"]).to eq([
            {"id" => child.id, "name" => "analyzer", "session_state" => "awaiting"}
          ])
        end
      end

      context "for a bare session with no skills, workflow, goals, or children" do
        before do
          create(:session, id: session_id)
          subscribe(session_id: session_id)
        end

        it "exposes empty collections, nil scalars, and omits the children key" do
          changed = transmissions.find { |t| t["action"] == "session_changed" }

          expect(changed).to include(
            "name" => nil,
            "active_skills" => [],
            "active_workflow" => nil,
            "goals" => []
          )
          expect(changed).not_to have_key("children")
        end
      end

      it "propagates parent_session_id for child sessions" do
        parent = create(:session)
        child = create(:session, parent_session: parent)

        subscribe(session_id: child.id)

        changed = transmissions.find { |t| t["action"] == "session_changed" }
        expect(changed["parent_session_id"]).to eq(parent.id)
      end
    end

    it "transmits chat history newest-first to prevent render thrashing" do
      session = create(:session, id: session_id)
      create(:message, :user_message, session: session, payload: {"type" => "user_message", "content" => "hello"}, timestamp: 1)
      create(:message, :agent_message, session: session, payload: {"type" => "agent_message", "content" => "hi there"}, timestamp: 2)
      create(:message, :tool_call, session: session, payload: {"type" => "tool_call", "content" => "calling bash", "tool_name" => "bash"}, timestamp: 3)

      subscribe(session_id: session_id)

      history = transmissions.reject { |t| t["action"] }
      expect(history.map { |h| h["content"] }).to eq(["calling bash", "hi there", "hello"])
    end

    it "decorates history entries with structured output keyed by view_mode" do
      session = create(:session, id: session_id, view_mode: "verbose")
      create(:message, :user_message, session: session, payload: {"type" => "user_message", "content" => "hello"}, timestamp: 1)

      subscribe(session_id: session_id)

      history = transmissions.reject { |t| t["action"] }
      expect(history[0]["rendered"]).to eq("verbose" => {"role" => :user, "content" => "hello", "timestamp" => 1})
    end

    it "includes system_message events in history" do
      session = create(:session, id: session_id)
      create(:message, :user_message, session: session, payload: {"type" => "user_message", "content" => "hello"}, timestamp: 1)
      create(:message, :system_message, session: session, payload: {"type" => "system_message", "content" => "MCP: server failed"}, timestamp: 2)

      subscribe(session_id: session_id)

      types = transmissions.reject { |t| t["action"] }.map { |h| h["type"] }
      expect(types).to include("system_message")
    end

    it "transmits session_changed then view_mode for a session with no messages" do
      create(:session, id: session_id)

      subscribe(session_id: session_id)

      actions = transmissions.select { |t| t["action"] }.map { |t| t["action"] }
      expect(actions).to eq(%w[session_changed view_mode])
    end
  end

  describe "#receive" do
    it "broadcasts the received data to the session stream" do
      create(:session, id: session_id)
      subscribe(session_id: session_id)
      data = {"type" => "user_message", "content" => "hello"}

      expect { perform(:receive, data) }
        .to have_broadcasted_to(stream_name).with(hash_including(data))
    end
  end

  describe "#speak" do
    let!(:session) { create(:session, id: session_id) }

    before { subscribe(session_id: session_id) }

    it "creates an active user_message PendingMessage with bounce_back enabled" do
      expect {
        perform(:speak, {"content" => "hello brain"})
      }.to change(PendingMessage, :count).by(1)

      pm = session.pending_messages.last
      expect(pm.content).to eq("hello brain")
      expect(pm.message_type).to eq("user_message")
      expect(pm.kind).to eq("active")
      expect(pm).to be_bounce_back
    end

    it "ignores empty content" do
      expect { perform(:speak, {"content" => "  "}) }
        .not_to change(PendingMessage, :count)
    end

    it "ignores nil content" do
      expect { perform(:speak, {"content" => nil}) }
        .not_to change(PendingMessage, :count)
    end

    it "strips whitespace from content" do
      perform(:speak, {"content" => "  hello  "})

      pm = session.pending_messages.last
      expect(pm.content).to eq("hello")
    end

    it "does not persist a Message directly — promotion belongs to DrainJob" do
      expect { perform(:speak, {"content" => "hi"}) }
        .not_to change { session.messages.count }
    end
  end

  describe "#recall_pending" do
    let!(:session) { create(:session, id: session_id) }

    before { subscribe(session_id: session_id) }

    it "deletes the PendingMessage" do
      pm = create(:pending_message, session: session)

      expect { perform(:recall_pending, {"pending_message_id" => pm.id}) }
        .to change(PendingMessage, :count).by(-1)
    end

    it "ignores pending messages from other sessions" do
      other = create(:session)
      pm = create(:pending_message, session: other)

      expect { perform(:recall_pending, {"pending_message_id" => pm.id}) }
        .not_to change(PendingMessage, :count)
    end

    it "ignores invalid pending_message_id" do
      expect {
        perform(:recall_pending, {"pending_message_id" => 0})
      }.not_to change(PendingMessage, :count)
    end
  end

  describe "#interrupt_execution" do
    let!(:session) { create(:session, id: session_id) }

    before { subscribe(session_id: session_id) }

    context "when session is not idle" do
      before { session.start_processing! }

      it "sets interrupt_requested on the session" do
        perform(:interrupt_execution, {})

        expect(session.reload.interrupt_requested?).to be true
      end

      it "broadcasts interrupt_acknowledged" do
        expect { perform(:interrupt_execution, {}) }
          .to have_broadcasted_to("session_#{session_id}")
          .with(hash_including("action" => "interrupt_acknowledged"))
      end

      it "cascades interrupt to non-idle child sessions" do
        child = create(:session, :awaiting, parent_session_id: session.id)

        perform(:interrupt_execution, {})

        expect(child.reload.interrupt_requested?).to be true
      end

      it "does not cascade to idle child sessions" do
        child = create(:session, parent_session_id: session.id)

        perform(:interrupt_execution, {})

        expect(child.reload.interrupt_requested?).to be false
      end
    end

    context "when session is idle" do
      it "does not set interrupt_requested" do
        perform(:interrupt_execution, {})

        expect(session.reload.interrupt_requested?).to be false
      end

      it "does not broadcast interrupt_acknowledged" do
        expect { perform(:interrupt_execution, {}) }
          .not_to have_broadcasted_to("session_#{session_id}")
      end
    end
  end

  describe "#list_sessions" do
    before do
      create(:session, id: session_id)
      subscribe(session_id: session_id)
    end

    it "returns recent root sessions newest-first with name and LLM message count" do
      older = create(:session, name: "🧠 Brainstorm")
      create(:message, :user_message, session: older)
      create(:message, :agent_message, session: older)
      newer = create(:session)

      perform(:list_sessions, {"limit" => 10})
      sessions = transmissions.last.fetch("sessions")

      expect(sessions.size).to eq(3)
      expect(sessions.map { |s| s["id"] }).to eq([newer.id, older.id, session_id])
      expect(sessions.find { |s| s["id"] == older.id }).to include(
        "name" => "🧠 Brainstorm", "message_count" => 2
      )
      expect(sessions.find { |s| s["id"] == newer.id }["name"]).to be_nil
    end

    it "excludes child sessions from the top level" do
      parent = create(:session)
      create(:session, parent_session: parent, prompt: "sub-agent task")

      perform(:list_sessions, {"limit" => 10})

      ids = transmissions.last["sessions"].map { |s| s["id"] }
      expect(ids).to contain_exactly(parent.id, session_id)
    end

    it "nests children under their parent with id, name, state, and message count" do
      parent = create(:session)
      child = create(:session, :awaiting, parent_session: parent, prompt: "research", name: "codebase-analyzer")
      create(:message, :user_message, session: child)
      create(:message, :agent_message, session: child)

      perform(:list_sessions, {"limit" => 10})
      parent_entry = transmissions.last["sessions"].find { |s| s["id"] == parent.id }

      expect(parent_entry["children"]).to eq([
        {
          "id" => child.id,
          "name" => "codebase-analyzer",
          "session_state" => "awaiting",
          "message_count" => 2,
          "created_at" => child.created_at.iso8601
        }
      ])
    end

    it "sorts children by created_at" do
      parent = create(:session)
      older = create(:session, parent_session: parent, prompt: "first", name: "alpha", created_at: 2.minutes.ago)
      newer = create(:session, parent_session: parent, prompt: "second", name: "beta", created_at: 1.minute.ago)

      perform(:list_sessions, {"limit" => 10})

      children = transmissions.last["sessions"].first["children"]
      expect(children.map { |c| c["id"] }).to eq([older.id, newer.id])
    end

    it "omits the children key entirely when a session has no children" do
      create(:session)

      perform(:list_sessions, {"limit" => 10})

      expect(transmissions.last["sessions"].first).not_to have_key("children")
    end

    it "respects the limit parameter" do
      3.times { create(:session) }

      perform(:list_sessions, {"limit" => 2})

      expect(transmissions.last["sessions"].size).to eq(2)
    end

    it "defaults to DEFAULT_LIST_LIMIT when limit is omitted" do
      (SessionChannel::DEFAULT_LIST_LIMIT + 2).times { create(:session) }

      perform(:list_sessions, {})

      expect(transmissions.last["sessions"].size).to eq(SessionChannel::DEFAULT_LIST_LIMIT)
    end

    it "clamps limit to MAX_LIST_LIMIT" do
      (SessionChannel::MAX_LIST_LIMIT + 5).times { create(:session) }

      perform(:list_sessions, {"limit" => SessionChannel::MAX_LIST_LIMIT + 50})

      expect(transmissions.last["sessions"].size).to eq(SessionChannel::MAX_LIST_LIMIT)
    end

    it "returns only the current session when no others exist" do
      perform(:list_sessions, {})

      expect(transmissions.last["sessions"].map { |s| s["id"] }).to eq([session_id])
    end
  end

  describe "#create_session" do
    before do
      create(:session, id: session_id)
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
    let!(:source_session) { create(:session, id: session_id) }
    let!(:target_session) { create(:session) }

    before do
      create(:message, :user_message, session: target_session, payload: {"type" => "user_message", "content" => "old msg"}, timestamp: 1)
      create(:message, :agent_message, session: target_session, payload: {"type" => "agent_message", "content" => "old reply"}, timestamp: 2)
      subscribe(session_id: session_id)
    end

    it "transmits session_changed with the target session info including view_mode" do
      perform(:switch_session, {"session_id" => target_session.id})

      changed = transmissions.reverse.find { |t| t["action"] == "session_changed" }
      expect(changed["session_id"]).to eq(target_session.id)
      expect(changed["message_count"]).to eq(2)
      expect(changed["view_mode"]).to eq("basic")
    end

    it "transmits chat history from the target session newest-first" do
      perform(:switch_session, {"session_id" => target_session.id})

      history = transmissions.select { |t| t["type"].in?(%w[user_message agent_message]) }
      expect(history.size).to eq(2)
      expect(history[0]["content"]).to eq("old reply")
      expect(history[1]["content"]).to eq("old msg")
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
    let!(:session) { create(:session, id: session_id) }

    before do
      create(:message, :user_message, session: session, payload: {"type" => "user_message", "content" => "hello"}, timestamp: 1)
      create(:message, :agent_message, session: session, payload: {"type" => "agent_message", "content" => "hi"}, timestamp: 2)
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
    let!(:session) { create(:session, id: session_id, view_mode: "debug") }

    it "prepends system prompt in debug mode history when prompt exists" do
      allow_any_instance_of(Session).to receive(:system_prompt).and_return("You are Anima.")
      create(:message, :user_message, session: session, payload: {"type" => "user_message", "content" => "hi"}, timestamp: 1)

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
      create(:message, :user_message, session: session, payload: {"type" => "user_message", "content" => "hi"}, timestamp: 1)

      subscribe(session_id: session_id)

      history = transmissions.reject { |t| t["action"] }
      system_prompt_msg = history.find { |t| t["type"] == "system_prompt" }
      expect(system_prompt_msg).to be_present
      expect(system_prompt_msg["rendered"]["debug"]["content"]).to include("Soul")
    end

    it "does not prepend system prompt in basic mode" do
      session.update!(view_mode: "basic")
      allow_any_instance_of(Session).to receive(:system_prompt).and_return("You are Anima.")
      create(:message, :user_message, session: session, payload: {"type" => "user_message", "content" => "hi"}, timestamp: 1)

      subscribe(session_id: session_id)

      history = transmissions.reject { |t| t["action"] }
      system_prompt_msg = history.find { |t| t["type"] == "system_prompt" }
      expect(system_prompt_msg).to be_nil
    end

    it "broadcasts system prompt on view mode change to debug" do
      session.update!(view_mode: "basic")
      allow_any_instance_of(Session).to receive(:system_prompt).and_return("You are Anima.")
      create(:message, :user_message, session: session, payload: {"type" => "user_message", "content" => "hi"}, timestamp: 1)

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
    let!(:session) { create(:session, id: session_id, view_mode: "debug") }

    it "includes token info in debug-decorated user messages" do
      create(:message, :user_message, session: session,
        payload: {"type" => "user_message", "content" => "hello"},
        timestamp: 1, token_count: 5)

      subscribe(session_id: session_id)

      msg = transmissions.find { |t| t["type"] == "user_message" }
      expect(msg.dig("rendered", "debug", "tokens")).to eq(5)
    end

    it "includes tool_use_id in debug-decorated tool calls" do
      create(:message, :bash_tool_call, session: session,
        payload: {"type" => "tool_call", "content" => "calling bash",
                  "tool_name" => "bash", "tool_input" => {"command" => "ls"},
                  "tool_use_id" => "toolu_abc"},
        tool_use_id: "toolu_abc", timestamp: 1)

      subscribe(session_id: session_id)

      msg = transmissions.find { |t| t["type"] == "tool_call" }
      expect(msg.dig("rendered", "debug")).to include("tool_use_id" => "toolu_abc", "tool" => "bash")
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
