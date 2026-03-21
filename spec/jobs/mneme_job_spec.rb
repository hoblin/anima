# frozen_string_literal: true

require "rails_helper"

RSpec.describe MnemeJob do
  let(:session) { Session.create! }
  let(:runner) { instance_double(Mneme::Runner, call: nil) }

  before do
    allow(Mneme::Runner).to receive(:new).and_return(runner)
  end

  it "runs Mneme for the given session" do
    described_class.perform_now(session.id)

    expect(runner).to have_received(:call)
  end

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
    expect { described_class.perform_now(-1) }.not_to raise_error
  end
end
