# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRequestJob do
  let(:session) { Session.create! }
  let(:agent_loop) { instance_double(AgentLoop, run: nil, finalize: nil) }

  before do
    allow(AgentLoop).to receive(:new).and_return(agent_loop)
    allow(Mcp::ClientManager).to receive(:new)
      .and_return(instance_double(Mcp::ClientManager, register_tools: []))
    allow(Anima::Settings).to receive(:analytical_brain_blocking_on_user_message).and_return(false)
  end

  describe "retry configuration" do
    it "retries on TransientError" do
      expect(described_class.rescue_handlers).to include(
        satisfy { |handler| handler[0] == "Providers::Anthropic::TransientError" }
      )
    end

    it "discards on AuthenticationError" do
      expect(described_class.rescue_handlers).to include(
        satisfy { |handler| handler[0] == "Providers::Anthropic::AuthenticationError" }
      )
    end

    it "discards on RecordNotFound" do
      expect(described_class.rescue_handlers).to include(
        satisfy { |handler| handler[0] == "ActiveRecord::RecordNotFound" }
      )
    end
  end

  describe "#perform" do
    it "runs the agent loop for the given session" do
      session.events.create!(event_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

      described_class.perform_now(session.id)

      expect(agent_loop).to have_received(:run)
    end

    it "sets processing flag during execution" do
      session.events.create!(event_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

      processing_during_run = nil
      allow(agent_loop).to receive(:run) do
        processing_during_run = session.reload.processing?
      end

      described_class.perform_now(session.id)

      expect(processing_during_run).to be true
      expect(session.reload.processing?).to be false
    end

    it "skips execution when session is already processing" do
      session.update!(processing: true)
      session.events.create!(event_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

      described_class.perform_now(session.id)

      expect(agent_loop).not_to have_received(:run)
      expect(session.reload.processing?).to be false
    end

    context "parent session broadcasts" do
      let(:parent) { Session.create! }
      let(:child) { Session.create!(parent_session: parent, prompt: "task") }

      it "broadcasts children_updated when claiming processing" do
        child.events.create!(event_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

        expect(ActionCable.server).to receive(:broadcast).with(
          "session_#{parent.id}",
          hash_including("action" => "children_updated")
        ).at_least(:once)

        described_class.perform_now(child.id)
      end

      it "broadcasts children_updated when releasing processing" do
        child.events.create!(event_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

        broadcasts = []
        allow(ActionCable.server).to receive(:broadcast) { |stream, data| broadcasts << data }

        described_class.perform_now(child.id)

        children_updates = broadcasts.select { |b| b["action"] == "children_updated" }
        expect(children_updates.size).to be >= 2 # claim + release
      end

      it "does not broadcast for root sessions" do
        session.events.create!(event_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

        expect(ActionCable.server).not_to receive(:broadcast)

        described_class.perform_now(session.id)
      end
    end

    context "blocking analytical brain" do
      before { allow(Anima::Settings).to receive(:analytical_brain_blocking_on_user_message).and_return(true) }

      it "runs analytical brain synchronously before the agent loop when enabled" do
        session.events.create!(event_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

        analytical_brain_ran = false
        allow(AnalyticalBrain::Runner).to receive(:new).and_wrap_original do |method, *args|
          runner = method.call(*args)
          allow(runner).to receive(:call) { analytical_brain_ran = true }
          runner
        end

        described_class.perform_now(session.id)

        expect(analytical_brain_ran).to be true
      end

      it "skips blocking analytical brain for sub-agent sessions" do
        parent = Session.create!
        child = Session.create!(parent_session: parent, prompt: "sub-agent")
        child.events.create!(event_type: "user_message", payload: {"content" => "task"}, timestamp: 1)
        child.events.create!(event_type: "agent_message", payload: {"content" => "done"}, timestamp: 2)

        expect(AnalyticalBrain::Runner).not_to receive(:new)

        described_class.perform_now(child.id)
      end

      it "continues with agent loop even if analytical brain fails" do
        session.events.create!(event_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)
        session.events.create!(event_type: "agent_message", payload: {"content" => "Hi"}, timestamp: 2)

        allow(AnalyticalBrain::Runner).to receive(:new).and_raise(RuntimeError, "brain exploded")

        expect { described_class.perform_now(session.id) }.not_to raise_error
        expect(agent_loop).to have_received(:run)
      end
    end

    it "schedules analytical brain after the agent loop completes" do
      session.events.create!(event_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)
      session.events.create!(event_type: "agent_message", payload: {"content" => "Hi!"}, timestamp: 2)

      expect { described_class.perform_now(session.id) }
        .to have_enqueued_job(AnalyticalBrainJob).with(session.id)
    end

    it "finalizes the agent loop after completion" do
      session.events.create!(event_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

      described_class.perform_now(session.id)

      expect(agent_loop).to have_received(:finalize)
    end

    it "finalizes the agent loop even on error" do
      session.events.create!(event_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

      allow(agent_loop).to receive(:run).and_raise(Providers::Anthropic::AuthenticationError, "bad token")

      described_class.perform_now(session.id)

      expect(agent_loop).to have_received(:finalize)
    end

    it "clears interrupt_requested flag after completion" do
      session.update_column(:interrupt_requested, true)
      session.events.create!(event_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

      described_class.perform_now(session.id)

      expect(session.reload.interrupt_requested?).to be false
    end

    it "clears interrupt_requested flag even on error" do
      session.update_column(:interrupt_requested, true)
      session.events.create!(event_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

      allow(agent_loop).to receive(:run).and_raise(Providers::Anthropic::AuthenticationError, "bad token")

      described_class.perform_now(session.id)

      expect(session.reload.interrupt_requested?).to be false
    end

    it "clears processing flag even on error" do
      session.events.create!(event_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

      allow(agent_loop).to receive(:run).and_raise(Providers::Anthropic::AuthenticationError, "bad token")

      described_class.perform_now(session.id)

      expect(session.reload.processing?).to be false
    end
  end

  describe "non-transient error handling" do
    before do
      session.events.create!(event_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)
    end

    context "authentication failure (HTTP 401)" do
      before do
        allow(agent_loop).to receive(:run).and_raise(
          Providers::Anthropic::AuthenticationError, "Invalid bearer token"
        )
      end

      it "broadcasts authentication_required signal via ActionCable" do
        expect {
          described_class.perform_now(session.id)
        }.to have_broadcasted_to("session_#{session.id}")
          .with(a_hash_including("action" => "authentication_required"))
      end
    end

    context "deleted session" do
      it "discards without retrying when session does not exist" do
        expect {
          described_class.perform_now(-1)
        }.not_to raise_error
      end
    end
  end

  describe "bounce back" do
    let!(:user_event) do
      session.events.create!(
        event_type: "user_message",
        payload: {"type" => "user_message", "content" => "Hello"},
        timestamp: 1
      )
    end

    context "on authentication failure" do
      before do
        allow(agent_loop).to receive(:run).and_raise(
          Providers::Anthropic::AuthenticationError, "Invalid bearer token"
        )
      end

      it "deletes the orphan user_message event" do
        described_class.perform_now(session.id)

        expect(Event.find_by(id: user_event.id)).to be_nil
      end

      it "broadcasts bounce_back with original content and error" do
        expect {
          described_class.perform_now(session.id)
        }.to have_broadcasted_to("session_#{session.id}")
          .with(a_hash_including(
            "action" => "bounce_back",
            "content" => "Hello",
            "event_id" => user_event.id,
            "message" => a_string_including("Authentication failed")
          ))
      end

      it "preserves system_message events (only deletes user_message)" do
        system_event = session.events.create!(
          event_type: "system_message",
          payload: {"type" => "system_message", "content" => "Retrying..."},
          timestamp: 2
        )

        described_class.perform_now(session.id)

        expect(Event.find_by(id: system_event.id)).to be_present
      end
    end

    context "on exhausted transient retries" do
      it "deletes the orphan user_message event via bounce_back_user_event" do
        described_class.bounce_back_user_event(session.id, "Connection refused")

        expect(Event.find_by(id: user_event.id)).to be_nil
      end

      it "broadcasts bounce_back with original content" do
        expect {
          described_class.bounce_back_user_event(session.id, "Connection refused")
        }.to have_broadcasted_to("session_#{session.id}")
          .with(a_hash_including(
            "action" => "bounce_back",
            "content" => "Hello",
            "event_id" => user_event.id,
            "message" => "Connection refused"
          ))
      end
    end

    it "does not bounce when no user_message exists" do
      user_event.destroy!

      expect {
        described_class.bounce_back_user_event(session.id, "Error")
      }.not_to raise_error
    end

    it "only bounces the most recent user_message" do
      older_event = session.events.create!(
        event_type: "user_message",
        payload: {"type" => "user_message", "content" => "Older"},
        timestamp: 0
      )

      described_class.bounce_back_user_event(session.id, "Error")

      # Most recent (user_event) should be deleted (higher id)
      expect(Event.find_by(id: user_event.id)).to be_nil
      # Older one should remain
      expect(Event.find_by(id: older_event.id)).to be_present
    end
  end
end
