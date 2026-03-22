# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRequestJob, "bounce back" do
  let(:session) { Session.create! }
  let(:agent_loop) { instance_double(AgentLoop, deliver!: nil, run: nil, finalize: nil) }

  before do
    allow(AgentLoop).to receive(:new).and_return(agent_loop)
    allow(Mcp::ClientManager).to receive(:new)
      .and_return(instance_double(Mcp::ClientManager, register_tools: []))
    allow(Anima::Settings).to receive(:analytical_brain_blocking_on_user_message).and_return(false)
  end

  describe "deliver_persisted_event" do
    let!(:event) { session.create_user_event("hello") }

    context "when LLM delivery succeeds" do
      before do
        allow(agent_loop).to receive(:deliver!)
      end

      it "keeps the user event" do
        expect {
          described_class.perform_now(session.id, event_id: event.id)
        }.not_to change(Event, :count)
      end

      it "continues the agent loop after delivery" do
        described_class.perform_now(session.id, event_id: event.id)

        expect(agent_loop).to have_received(:deliver!)
        expect(agent_loop).to have_received(:run)
        expect(agent_loop).to have_received(:finalize)
      end

      it "processes pending messages after the main loop" do
        session.events.create!(
          event_type: "user_message",
          payload: {"type" => "user_message", "content" => "pending msg", "status" => "pending"},
          status: Event::PENDING_STATUS,
          timestamp: 1
        )

        described_class.perform_now(session.id, event_id: event.id)

        expect(session.events.pending.count).to eq(0)
      end
    end

    context "when LLM delivery fails" do
      before do
        allow(agent_loop).to receive(:deliver!).and_raise(
          Providers::Anthropic::AuthenticationError, "No token configured"
        )
      end

      it "deletes the pre-persisted user event" do
        expect {
          described_class.perform_now(session.id, event_id: event.id)
        }.to change(Event, :count).by(-1)
      end

      it "emits a BounceBack event with original content and event_id" do
        emitted = []
        allow(Events::Bus).to receive(:emit).and_wrap_original do |method, emitted_event|
          emitted << emitted_event
          method.call(emitted_event)
        end

        described_class.perform_now(session.id, event_id: event.id)

        bounce = emitted.find { |e| e.is_a?(Events::BounceBack) }
        expect(bounce).to be_present
        expect(bounce.content).to eq("hello")
        expect(bounce.error).to include("No token configured")
        expect(bounce.event_id).to eq(event.id)
      end

      it "broadcasts authentication_required for auth errors" do
        broadcasts = []
        allow(ActionCable.server).to receive(:broadcast) { |stream, data| broadcasts << data }

        described_class.perform_now(session.id, event_id: event.id)

        auth_required = broadcasts.find { |b| b["action"] == "authentication_required" }
        expect(auth_required).to be_present
      end

      it "does not continue the agent loop" do
        described_class.perform_now(session.id, event_id: event.id)

        expect(agent_loop).not_to have_received(:run)
      end

      it "still releases the processing lock" do
        described_class.perform_now(session.id, event_id: event.id)

        expect(session.reload.processing?).to be false
      end

      it "still finalizes the agent loop" do
        described_class.perform_now(session.id, event_id: event.id)

        expect(agent_loop).to have_received(:finalize)
      end
    end

    context "when LLM returns a transient error" do
      before do
        allow(agent_loop).to receive(:deliver!).and_raise(
          Providers::Anthropic::RateLimitError, "Rate limit exceeded"
        )
      end

      it "deletes the pre-persisted user event" do
        expect {
          described_class.perform_now(session.id, event_id: event.id)
        }.to change(Event, :count).by(-1)
      end

      it "emits a BounceBack with the rate limit error" do
        emitted = []
        allow(Events::Bus).to receive(:emit).and_wrap_original do |method, emitted_event|
          emitted << emitted_event
          method.call(emitted_event)
        end

        described_class.perform_now(session.id, event_id: event.id)

        bounce = emitted.find { |e| e.is_a?(Events::BounceBack) }
        expect(bounce.error).to include("Rate limit exceeded")
      end
    end

    context "when event was already deleted" do
      before do
        event.destroy!
      end

      it "exits gracefully without calling deliver!" do
        described_class.perform_now(session.id, event_id: event.id)

        expect(agent_loop).not_to have_received(:deliver!)
      end
    end
  end

  describe "standard path (no event_id)" do
    it "runs the agent loop without delivery verification" do
      session.events.create!(event_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

      described_class.perform_now(session.id)

      expect(agent_loop).to have_received(:run)
      expect(agent_loop).not_to have_received(:deliver!)
    end
  end
end
