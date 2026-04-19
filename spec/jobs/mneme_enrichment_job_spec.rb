# frozen_string_literal: true

require "rails_helper"

RSpec.describe MnemeEnrichmentJob do
  let(:session) { Session.create! }
  let(:recall) { instance_double(Mneme::PassiveRecall, call: nil) }

  before do
    allow(Mneme::PassiveRecall).to receive(:new).with(session).and_return(recall)
    allow(Session).to receive(:find).with(session.id).and_return(session)
    allow(Session).to receive(:find).with(-1).and_call_original
  end

  it "discards on missing session" do
    expect { described_class.perform_now(-1) }.not_to raise_error
  end

  it "runs Mneme::PassiveRecall for the session" do
    allow(Events::Bus).to receive(:emit)

    described_class.perform_now(session.id)

    expect(recall).to have_received(:call)
  end

  it "emits StartMelete to hand off to the next pipeline stage" do
    emitted = capture_emissions

    described_class.perform_now(session.id, pending_message_id: 42)

    melete = emitted.find { |e| e.is_a?(Events::StartMelete) }
    expect(melete).to be_present
    expect(melete.session_id).to eq(session.id)
    expect(melete.pending_message_id).to eq(42)
  end

  it "propagates exceptions from PassiveRecall (no defensive rescue)" do
    allow(recall).to receive(:call).and_raise(StandardError.new("recall crashed"))

    expect {
      described_class.perform_now(session.id)
    }.to raise_error(StandardError, "recall crashed")
  end
end
