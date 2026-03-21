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

  describe "L2 compression trigger" do
    let(:l2_runner) { instance_double(Mneme::L2Runner, call: nil) }

    before do
      allow(Mneme::L2Runner).to receive(:new).and_return(l2_runner)
      allow(Anima::Settings).to receive(:mneme_l2_snapshot_threshold).and_return(3)
    end

    it "triggers L2 compression when enough uncovered L1 snapshots accumulate" do
      3.times do |i|
        session.snapshots.create!(
          text: "Summary #{i}", from_event_id: i * 10 + 1,
          to_event_id: (i + 1) * 10, level: 1, token_count: 50
        )
      end

      described_class.perform_now(session.id)

      expect(l2_runner).to have_received(:call)
    end

    it "does not trigger L2 compression when below threshold" do
      session.snapshots.create!(
        text: "Summary", from_event_id: 1, to_event_id: 10, level: 1, token_count: 50
      )

      described_class.perform_now(session.id)

      expect(Mneme::L2Runner).not_to have_received(:new)
    end

    it "excludes L1 snapshots covered by L2 from the count" do
      3.times do |i|
        session.snapshots.create!(
          text: "Summary #{i}", from_event_id: i * 10 + 1,
          to_event_id: (i + 1) * 10, level: 1, token_count: 50
        )
      end
      # L2 covers all three
      session.snapshots.create!(
        text: "L2", from_event_id: 1, to_event_id: 30, level: 2, token_count: 80
      )

      described_class.perform_now(session.id)

      expect(Mneme::L2Runner).not_to have_received(:new)
    end
  end
end
