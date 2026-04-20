# frozen_string_literal: true

require "rails_helper"

RSpec.describe MnemeEnrichmentJob do
  let(:session) { Session.create! }
  let(:recall) { instance_double(Mneme::RecallRunner, call: nil) }

  before do
    allow(Mneme::RecallRunner).to receive(:new).with(session).and_return(recall)
    allow(Session).to receive(:find).with(session.id).and_return(session)
    allow(Session).to receive(:find).with(-1).and_call_original
  end

  it "discards on missing session" do
    expect { described_class.perform_now(-1) }.not_to raise_error
  end

  it "runs the Mneme recall loop for the session" do
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

  context "when the recall loop raises" do
    before { allow(recall).to receive(:call).and_raise(StandardError.new("recall crashed")) }

    it "swallows the error so the drain pipeline still progresses" do
      expect { described_class.perform_now(session.id) }.not_to raise_error
    end

    it "logs the failure to both the Rails log and the Mneme log" do
      allow(Rails.logger).to receive(:error)
      allow(Mneme.logger).to receive(:error)

      described_class.perform_now(session.id)

      expect(Rails.logger).to have_received(:error).with(/Mneme FAILED .*recall crashed/)
      expect(Mneme.logger).to have_received(:error).with(/recall crashed/)
    end

    it "still emits StartMelete so the session is not stranded" do
      emitted = capture_emissions

      described_class.perform_now(session.id, pending_message_id: 42)

      expect(emitted.map(&:class)).to include(Events::StartMelete)
    end
  end
end
