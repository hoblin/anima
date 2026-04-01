# frozen_string_literal: true

require "rails_helper"

RSpec.describe PassiveRecallJob do
  let(:session) { Session.create! }

  before do
    allow(Anima::Settings).to receive(:token_budget).and_return(190_000)
    allow(Anima::Settings).to receive(:recall_budget_fraction).and_return(0.05)
    allow(Anima::Settings).to receive(:recall_max_results).and_return(5)
    allow(Anima::Settings).to receive(:recall_max_snippet_tokens).and_return(512)
  end

  it "discards on RecordNotFound" do
    expect { described_class.perform_now(-1) }.not_to raise_error
  end

  it "creates recall pending messages for matching results" do
    other_session = Session.create!
    other_session.messages.create!(
      message_type: "user_message",
      payload: {"content" => "The authentication module is broken"},
      timestamp: Time.current.to_ns
    )

    session.goals.create!(description: "Fix the authentication module")

    expect { described_class.perform_now(session.id) }
      .to change { session.pending_messages.where(source_type: "recall").count }.by_at_least(1)
  end

  it "does nothing when no goals exist" do
    expect { described_class.perform_now(session.id) }
      .not_to change { session.pending_messages.count }
  end
end
