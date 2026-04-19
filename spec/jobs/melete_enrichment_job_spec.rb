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

  it "emits StartProcessing after the runner finishes" do
    emitted = capture_emissions

    described_class.perform_now(session.id, pending_message_id: 99)

    processing = emitted.find { |e| e.is_a?(Events::StartProcessing) }
    expect(processing).to be_present
    expect(processing.session_id).to eq(session.id)
    expect(processing.pending_message_id).to eq(99)
  end

  it "propagates exceptions from the runner (no defensive rescue)" do
    allow(runner).to receive(:call).and_raise(StandardError.new("runner crashed"))

    expect {
      described_class.perform_now(session.id)
    }.to raise_error(StandardError, "runner crashed")
  end
end
