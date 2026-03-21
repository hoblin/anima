# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRequestJob, "bounce back" do
  let(:session) { Session.create! }
  let(:agent_loop) { instance_double(AgentLoop, run: nil, finalize: nil) }

  before do
    allow(AgentLoop).to receive(:new).and_return(agent_loop)
    allow(Mcp::ClientManager).to receive(:new)
      .and_return(instance_double(Mcp::ClientManager, register_tools: []))
    allow(Anima::Settings).to receive(:analytical_brain_blocking_on_user_message).and_return(false)
  end

  describe "deliver_with_bounce_back" do
    context "when LLM delivery succeeds" do
      before do
        allow(agent_loop).to receive(:deliver!)
      end

      it "persists the user event" do
        expect {
          described_class.perform_now(session.id, content: "hello")
        }.to change { session.events.where(event_type: "user_message").count }.by(1)
      end

      it "stores the correct content in the event payload" do
        described_class.perform_now(session.id, content: "hello")

        event = session.events.last
        expect(event.payload["content"]).to eq("hello")
        expect(event.event_type).to eq("user_message")
      end

      it "broadcasts the event for optimistic UI" do
        expect(ActionCable.server).to receive(:broadcast)
          .with("session_#{session.id}", a_hash_including("type" => "user_message"))
          .at_least(:once)

        described_class.perform_now(session.id, content: "hello")
      end

      it "continues the agent loop after transaction commit" do
        described_class.perform_now(session.id, content: "hello")

        expect(agent_loop).to have_received(:deliver!)
        expect(agent_loop).to have_received(:run)
        expect(agent_loop).to have_received(:finalize)
      end

      it "processes pending messages after the main loop" do
        # Create a pending message
        session.events.create!(
          event_type: "user_message",
          payload: {"type" => "user_message", "content" => "pending msg", "status" => "pending"},
          status: Event::PENDING_STATUS,
          timestamp: 1
        )

        described_class.perform_now(session.id, content: "hello")

        expect(session.events.pending.count).to eq(0)
      end
    end

    context "when LLM delivery fails" do
      before do
        allow(agent_loop).to receive(:deliver!).and_raise(
          Providers::Anthropic::AuthenticationError, "No token configured"
        )
      end

      it "rolls back the user event (never persisted)" do
        expect {
          described_class.perform_now(session.id, content: "hello")
        }.not_to change(Event, :count)
      end

      it "emits a BounceBack event" do
        emitted = []
        allow(Events::Bus).to receive(:emit).and_wrap_original do |method, event|
          emitted << event
          method.call(event)
        end

        described_class.perform_now(session.id, content: "hello")

        bounce = emitted.find { |e| e.is_a?(Events::BounceBack) }
        expect(bounce).to be_present
        expect(bounce.content).to eq("hello")
        expect(bounce.error).to include("No token configured")
      end

      it "broadcasts authentication_required for auth errors" do
        broadcasts = []
        allow(ActionCable.server).to receive(:broadcast) { |stream, data| broadcasts << data }

        described_class.perform_now(session.id, content: "hello")

        auth_required = broadcasts.find { |b| b["action"] == "authentication_required" }
        expect(auth_required).to be_present
      end

      it "does not continue the agent loop" do
        described_class.perform_now(session.id, content: "hello")

        expect(agent_loop).not_to have_received(:run)
      end

      it "still releases the processing lock" do
        described_class.perform_now(session.id, content: "hello")

        expect(session.reload.processing?).to be false
      end

      it "still finalizes the agent loop" do
        described_class.perform_now(session.id, content: "hello")

        expect(agent_loop).to have_received(:finalize)
      end
    end

    context "when LLM returns a transient error" do
      before do
        allow(agent_loop).to receive(:deliver!).and_raise(
          Providers::Anthropic::RateLimitError, "Rate limit exceeded"
        )
      end

      it "rolls back the user event" do
        expect {
          described_class.perform_now(session.id, content: "hello")
        }.not_to change(Event, :count)
      end

      it "emits a BounceBack with the rate limit error" do
        emitted = []
        allow(Events::Bus).to receive(:emit).and_wrap_original do |method, event|
          emitted << event
          method.call(event)
        end

        described_class.perform_now(session.id, content: "hello")

        bounce = emitted.find { |e| e.is_a?(Events::BounceBack) }
        expect(bounce.error).to include("Rate limit exceeded")
      end
    end
  end

  describe "standard path (no content)" do
    before do
      allow(agent_loop).to receive(:deliver!)
    end

    it "runs the agent loop without transaction wrapping" do
      session.events.create!(event_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

      described_class.perform_now(session.id)

      expect(agent_loop).to have_received(:run)
      expect(agent_loop).not_to have_received(:deliver!)
    end
  end
end
