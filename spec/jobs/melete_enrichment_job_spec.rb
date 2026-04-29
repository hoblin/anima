# frozen_string_literal: true

require "rails_helper"

RSpec.describe MeleteEnrichmentJob do
  let(:session) { Session.create! }
  let(:runner) { instance_double(Melete::Runner, call: nil) }

  before do
    allow(Melete::Runner).to receive(:new).with(session).and_return(runner)
    allow(Session).to receive(:find).with(session.id).and_return(session)
    allow(Session).to receive(:find).with(-1).and_call_original
  end

  it "discards on missing session" do
    expect { described_class.perform_now(-1) }.not_to raise_error
  end

  it "runs Melete::Runner for a top-level session" do
    allow(Events::Bus).to receive(:emit)

    described_class.perform_now(session.id)

    expect(runner).to have_received(:call)
  end

  it "skips Melete::Runner for sub-agent sessions" do
    allow(session).to receive(:sub_agent?).and_return(true)
    allow(Events::Bus).to receive(:emit)

    described_class.perform_now(session.id)

    expect(runner).not_to have_received(:call)
  end

  describe "conditional handoff" do
    it "emits StartMneme when a goal is created during the runner call" do
      allow(runner).to receive(:call) do
        Events::Bus.emit(Events::GoalCreated.new(session_id: session.id, goal_id: 1))
      end
      emitted = capture_emissions

      described_class.perform_now(session.id, pending_message_id: 99)

      mneme = emitted.find { |e| e.is_a?(Events::StartMneme) }
      expect(mneme).to be_present
      expect(mneme.session_id).to eq(session.id)
      expect(mneme.pending_message_id).to eq(99)
      expect(emitted.map(&:class)).not_to include(Events::StartProcessing)
    end

    it "emits StartMneme when a goal is updated during the runner call" do
      allow(runner).to receive(:call) do
        Events::Bus.emit(Events::GoalUpdated.new(session_id: session.id, goal_id: 1))
      end
      emitted = capture_emissions

      described_class.perform_now(session.id, pending_message_id: 99)

      expect(emitted.map(&:class)).to include(Events::StartMneme)
      expect(emitted.map(&:class)).not_to include(Events::StartProcessing)
    end

    it "emits StartProcessing when no goal mutation event fires" do
      emitted = capture_emissions

      described_class.perform_now(session.id, pending_message_id: 99)

      processing = emitted.find { |e| e.is_a?(Events::StartProcessing) }
      expect(processing).to be_present
      expect(processing.pending_message_id).to eq(99)
      expect(emitted.map(&:class)).not_to include(Events::StartMneme)
    end

    it "ignores goal mutations from other sessions" do
      allow(runner).to receive(:call) do
        Events::Bus.emit(Events::GoalCreated.new(session_id: session.id + 1, goal_id: 1))
      end
      emitted = capture_emissions

      described_class.perform_now(session.id)

      expect(emitted.map(&:class)).to include(Events::StartProcessing)
      expect(emitted.map(&:class)).not_to include(Events::StartMneme)
    end

    it "emits StartProcessing for sub-agents (runner skipped, no goal events possible)" do
      allow(session).to receive(:sub_agent?).and_return(true)
      emitted = capture_emissions

      described_class.perform_now(session.id, pending_message_id: 7)

      expect(emitted.map(&:class)).to include(Events::StartProcessing)
      expect(emitted.map(&:class)).not_to include(Events::StartMneme)
    end
  end

  describe "subscriber lifecycle" do
    it "unsubscribes the listener even when the runner raises" do
      allow(runner).to receive(:call).and_raise(StandardError.new("runner crashed"))
      allow(Events::Bus).to receive(:subscribe).and_call_original
      allow(Events::Bus).to receive(:unsubscribe).and_call_original

      expect { described_class.perform_now(session.id) }.to raise_error(StandardError)

      expect(Events::Bus).to have_received(:subscribe)
        .with(an_instance_of(MeleteEnrichmentJob::GoalChangeListener))
      expect(Events::Bus).to have_received(:unsubscribe)
        .with(an_instance_of(MeleteEnrichmentJob::GoalChangeListener))
    end
  end

  it "propagates exceptions from the runner (no defensive rescue)" do
    allow(runner).to receive(:call).and_raise(StandardError.new("runner crashed"))

    expect {
      described_class.perform_now(session.id)
    }.to raise_error(StandardError, "runner crashed")
  end
end
