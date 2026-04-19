# frozen_string_literal: true

require "rails_helper"

RSpec.describe DrainJob do
  let(:session) { Session.create! }
  let(:provider) { instance_double(Providers::Anthropic, create_message: response) }
  let(:client) { instance_double(LLM::Client, provider: provider, model: "claude-test", max_tokens: 1000) }
  let(:registry) { instance_double(Tools::Registry, schemas: []) }
  let(:shell_session) { instance_double(ShellSession, finalize: nil) }
  let(:response) do
    Providers::Anthropic::ApiResponse.new(
      body: {"content" => [{"type" => "text", "text" => "hello"}], "stop_reason" => "end_turn"},
      api_metrics: {input_tokens: 10}
    )
  end

  before do
    allow(LLM::Client).to receive(:new).and_return(client)
    allow(Tools::Registry).to receive(:build).and_return(registry)
    allow(ShellSession).to receive(:for_session).and_return(shell_session)
    allow(session).to receive(:system_prompt).and_return("you are anima")
    allow(session).to receive(:broadcast_debug_context)
    allow(Session).to receive(:find).with(session.id).and_return(session)
    allow(Session).to receive(:find).with(-1).and_call_original
  end

  describe "#perform" do
    it "discards on missing session" do
      expect { described_class.perform_now(-1) }.not_to raise_error
    end

    it "releases the session without calling the LLM when mailbox is empty" do
      emitted = capture_emissions

      described_class.perform_now(session.id)

      expect(emitted.map(&:class)).not_to include(Events::LLMResponded)
      expect(session.reload.aasm_state).to eq("idle")
      expect(provider).not_to have_received(:create_message)
    end

    it "bails silently when another drain holds the session" do
      session.start_processing!

      expect { described_class.perform_now(session.id) }.not_to change { session.reload.aasm_state }
      expect(provider).not_to have_received(:create_message)
    end

    it "promotes an active user_message PM and emits LLMResponded" do
      create(:pending_message, session: session, content: "hi", message_type: "user_message")

      emitted = capture_emissions

      described_class.perform_now(session.id)

      expect(emitted.map(&:class)).to include(Events::LLMResponded)
      expect(session.pending_messages.count).to eq(0)
      expect(session.messages.where(message_type: "user_message").count).to eq(1)
    end

    it "flushes all tool_response PMs plus background phantom pairs in one drain" do
      session.start_processing! # idle → awaiting
      session.tool_received!     # awaiting → executing
      session.messages.create!(
        message_type: "tool_call",
        tool_use_id: "toolu_1",
        payload: {"type" => "tool_call", "tool_use_id" => "toolu_1"},
        timestamp: Time.current.to_ns
      )
      create(:pending_message, :tool_response, session: session, tool_use_id: "toolu_1")
      create(:pending_message, :from_mneme, session: session)

      emitted = capture_emissions

      described_class.perform_now(session.id)

      expect(emitted.map(&:class)).to include(Events::LLMResponded)
      expect(session.pending_messages.count).to eq(0)
      # 1 from the tool_response PM + 1 from the from_mneme phantom pair
      expect(session.messages.where(message_type: "tool_response").count).to eq(2)
    end

    context "when a non-bounce-back active PM triggers an error" do
      before do
        allow(provider).to receive(:create_message)
          .and_raise(Providers::Anthropic::Error.new("boom"))
      end

      it "releases to idle and re-raises" do
        create(:pending_message, :subagent, session: session, content: "from child")

        expect {
          described_class.perform_now(session.id)
        }.to raise_error(Providers::Anthropic::Error)

        expect(session.reload.aasm_state).to eq("idle")
      end
    end

    context "when a bounce_back user_message PM triggers a non-auth error" do
      before do
        allow(provider).to receive(:create_message)
          .and_raise(Providers::Anthropic::Error.new("boom"))
      end

      it "bounces the promoted message and swallows the error" do
        create(:pending_message, :bounce_back, session: session, content: "hi")

        emitted = capture_emissions

        expect { described_class.perform_now(session.id) }.not_to raise_error

        expect(emitted.map(&:class)).to include(Events::BounceBack)
        expect(session.messages.where(message_type: "user_message").count).to eq(0)
        expect(session.reload.aasm_state).to eq("idle")
      end
    end

    context "when a bounce_back PM hits an AuthenticationError" do
      before do
        allow(provider).to receive(:create_message)
          .and_raise(Providers::Anthropic::AuthenticationError.new("bad token"))
      end

      it "bounces the text AND emits AuthenticationRequired via discard_on" do
        create(:pending_message, :bounce_back, session: session, content: "hi")

        emitted = []
        allow(Events::Bus).to receive(:emit) { |event| emitted << event }

        described_class.perform_now(session.id)

        expect(emitted.map(&:class)).to include(Events::BounceBack, Events::AuthenticationRequired)
        expect(session.reload.aasm_state).to eq("idle")
      end
    end

    context "when the provider raises a transient error" do
      it "retries inline and recovers without a new job" do
        call_count = 0
        allow(provider).to receive(:create_message) do
          call_count += 1
          raise Providers::Anthropic::TransientError.new("overloaded") if call_count < 3
          response
        end
        allow_any_instance_of(described_class).to receive(:sleep)

        create(:pending_message, session: session, content: "hi", message_type: "user_message")

        emitted = capture_emissions

        described_class.perform_now(session.id)

        expect(emitted.map(&:class)).to include(Events::LLMResponded)
        expect(call_count).to eq(3)
      end

      it "emits a SystemMessage and re-raises after retry exhaustion" do
        allow(provider).to receive(:create_message)
          .and_raise(Providers::Anthropic::TransientError.new("overloaded"))
        allow_any_instance_of(described_class).to receive(:sleep)

        create(:pending_message, :subagent, session: session, content: "from child")

        emitted = []
        allow(Events::Bus).to receive(:emit) { |event| emitted << event }

        expect {
          described_class.perform_now(session.id)
        }.to raise_error(Providers::Anthropic::TransientError)

        expect(emitted.map(&:class)).to include(Events::SystemMessage)
      end
    end

    it "calls ShellSession#finalize in the ensure block" do
      create(:pending_message, session: session, content: "hi", message_type: "user_message")
      allow(Events::Bus).to receive(:emit)

      described_class.perform_now(session.id)

      expect(shell_session).to have_received(:finalize)
    end
  end
end
