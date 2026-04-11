# frozen_string_literal: true

require "rails_helper"

RSpec.describe MeleteJob do
  let(:session) { Session.create! }
  let(:runner) { instance_double(Melete::Runner, call: nil) }

  before do
    allow(Melete::Runner).to receive(:new).and_return(runner)
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

    it "discards on RecordNotFound" do
      expect(described_class.rescue_handlers).to include(
        satisfy { |handler| handler[0] == "ActiveRecord::RecordNotFound" }
      )
    end
  end

  describe "#perform" do
    it "runs the analytical brain for the given session" do
      described_class.perform_now(session.id)

      expect(runner).to have_received(:call)
    end

    it "discards the job if the session no longer exists" do
      expect { described_class.perform_now(999_999) }.not_to raise_error
    end
  end
end
