# frozen_string_literal: true

require "rails_helper"

RSpec.describe PassiveRecallJob do
  let(:session) { Session.create! }

  it "discards on RecordNotFound" do
    expect { described_class.perform_now(-1) }.not_to raise_error
  end

  it "delegates to Mneme::RecallRunner for the given session" do
    recall = instance_double(Mneme::RecallRunner, call: nil)
    expect(Mneme::RecallRunner).to receive(:new).with(session).and_return(recall)

    described_class.perform_now(session.id)

    expect(recall).to have_received(:call)
  end

  it "propagates recall-loop errors (no defensive rescue)" do
    recall = instance_double(Mneme::RecallRunner)
    allow(Mneme::RecallRunner).to receive(:new).and_return(recall)
    allow(recall).to receive(:call).and_raise(StandardError.new("boom"))

    expect {
      described_class.perform_now(session.id)
    }.to raise_error(StandardError, "boom")
  end
end
