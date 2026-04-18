# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRequestJob do
  let(:session) { create(:session) }
  let(:agent_loop) { instance_double(AgentLoop, run: nil, finalize: nil) }

  before do
    allow(AgentLoop).to receive(:new).and_return(agent_loop)
    allow(Mcp::ClientManager).to receive(:new)
      .and_return(instance_double(Mcp::ClientManager, register_tools: []))
    allow(Anima::Settings).to receive(:melete_blocking_on_user_message).and_return(false)
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
  end

  describe "#perform" do
    it "runs the agent loop for the given session" do
      session.messages.create!(message_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

      described_class.perform_now(session.id)

      expect(agent_loop).to have_received(:run)
    end

    it "transitions session to awaiting during execution" do
      session.messages.create!(message_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

      state_during_run = nil
      allow(agent_loop).to receive(:run) do
        state_during_run = session.reload.aasm_state
      end

      described_class.perform_now(session.id)

      expect(state_during_run).to eq("awaiting")
      expect(session.reload).to be_idle
    end

    it "skips execution when session is already processing" do
      session.start_processing!
      session.messages.create!(message_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

      described_class.perform_now(session.id)

      expect(agent_loop).not_to have_received(:run)
    end

    context "session state broadcasts" do
      let(:parent) { create(:session) }
      let(:child) { create(:session, :sub_agent, parent_session: parent, prompt: "task") }

      it "broadcasts session_state awaiting when claiming processing" do
        session.messages.create!(message_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

        expect(ActionCable.server).to receive(:broadcast).with(
          "session_#{session.id}",
          hash_including("action" => "session_state", "state" => "awaiting")
        )
        allow(ActionCable.server).to receive(:broadcast)

        described_class.perform_now(session.id)
      end

      it "broadcasts session_state idle when releasing processing" do
        session.messages.create!(message_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

        expect(ActionCable.server).to receive(:broadcast).with(
          "session_#{session.id}",
          hash_including("action" => "session_state", "state" => "idle")
        )
        allow(ActionCable.server).to receive(:broadcast)

        described_class.perform_now(session.id)
      end

      it "broadcasts child_state to parent stream when a sub-agent transitions" do
        child.messages.create!(message_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

        expect(ActionCable.server).to receive(:broadcast).with(
          "session_#{parent.id}",
          hash_including("action" => "child_state", "child_id" => child.id)
        ).at_least(:once)
        allow(ActionCable.server).to receive(:broadcast)

        described_class.perform_now(child.id)
      end

      it "does not broadcast child_state for root sessions" do
        session.messages.create!(message_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

        expect(ActionCable.server).not_to receive(:broadcast).with(
          anything,
          hash_including("action" => "child_state")
        )
        allow(ActionCable.server).to receive(:broadcast)

        described_class.perform_now(session.id)
      end
    end

    context "blocking Melete" do
      before { allow(Anima::Settings).to receive(:melete_blocking_on_user_message).and_return(true) }

      it "runs Melete synchronously before the agent loop when enabled" do
        session.messages.create!(message_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

        melete_ran = false
        allow(Melete::Runner).to receive(:new).and_wrap_original do |method, *args|
          runner = method.call(*args)
          allow(runner).to receive(:call) { melete_ran = true }
          runner
        end

        described_class.perform_now(session.id)

        expect(melete_ran).to be true
      end

      it "skips blocking Melete for sub-agent sessions" do
        child = create(:session, :sub_agent)
        child.messages.create!(message_type: "user_message", payload: {"content" => "task"}, timestamp: 1)
        child.messages.create!(message_type: "agent_message", payload: {"content" => "done"}, timestamp: 2)

        expect(Melete::Runner).not_to receive(:new)

        described_class.perform_now(child.id)
      end

      it "continues with agent loop even if Melete fails" do
        session.messages.create!(message_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)
        session.messages.create!(message_type: "agent_message", payload: {"content" => "Hi"}, timestamp: 2)

        allow(Melete::Runner).to receive(:new).and_raise(RuntimeError, "Melete exploded")

        expect { described_class.perform_now(session.id) }.not_to raise_error
        expect(agent_loop).to have_received(:run)
      end
    end

    it "schedules Melete after the agent loop completes" do
      session.messages.create!(message_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)
      session.messages.create!(message_type: "agent_message", payload: {"content" => "Hi!"}, timestamp: 2)

      expect { described_class.perform_now(session.id) }
        .to have_enqueued_job(MeleteJob).with(session.id)
    end

    it "finalizes the agent loop after completion" do
      session.messages.create!(message_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

      described_class.perform_now(session.id)

      expect(agent_loop).to have_received(:finalize)
    end

    it "finalizes the agent loop even on error" do
      session.messages.create!(message_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

      allow(agent_loop).to receive(:run).and_raise(Providers::Anthropic::AuthenticationError, "bad token")

      described_class.perform_now(session.id)

      expect(agent_loop).to have_received(:finalize)
    end

    it "clears interrupt_requested flag after completion" do
      session.update_column(:interrupt_requested, true)
      session.messages.create!(message_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

      described_class.perform_now(session.id)

      expect(session.reload.interrupt_requested?).to be false
    end

    it "clears interrupt_requested flag even on error" do
      session.update_column(:interrupt_requested, true)
      session.messages.create!(message_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

      allow(agent_loop).to receive(:run).and_raise(Providers::Anthropic::AuthenticationError, "bad token")

      described_class.perform_now(session.id)

      expect(session.reload.interrupt_requested?).to be false
    end

    it "returns session to idle even on error" do
      session.messages.create!(message_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

      allow(agent_loop).to receive(:run).and_raise(Providers::Anthropic::AuthenticationError, "bad token")

      described_class.perform_now(session.id)

      expect(session.reload).to be_idle
    end
  end

  describe "non-transient error handling" do
    before do
      session.messages.create!(message_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)
    end

    context "authentication failure (HTTP 401)" do
      before do
        allow(agent_loop).to receive(:run).and_raise(
          Providers::Anthropic::AuthenticationError, "Invalid bearer token"
        )
      end

      it "fails immediately without retrying" do
        emitted_events = []
        allow(Events::Bus).to receive(:emit).and_wrap_original do |method, event|
          emitted_events << event
          method.call(event)
        end

        described_class.perform_now(session.id)

        system_messages = emitted_events.select { |e| e.is_a?(Events::SystemMessage) }
        expect(system_messages.last.to_h[:content]).to include("Authentication failed")
      end

      it "broadcasts authentication_required signal via ActionCable" do
        expect {
          described_class.perform_now(session.id)
        }.to have_broadcasted_to("session_#{session.id}")
          .with(a_hash_including("action" => "authentication_required"))
      end
    end
  end
end
