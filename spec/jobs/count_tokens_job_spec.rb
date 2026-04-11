# frozen_string_literal: true

require "rails_helper"

RSpec.describe CountTokensJob do
  let(:session) { Session.create! }

  describe "#perform" do
    it "refines a Message token_count via the Anthropic API", :vcr do
      message = session.messages.create!(
        message_type: "user_message",
        payload: {"content" => "Hello, Claude"},
        timestamp: 1,
        token_count: 9999
      )

      described_class.perform_now(message)

      expect(message.reload.token_count).to be > 0
      expect(message.reload.token_count).not_to eq(9999)
    end

    it "refines a Snapshot token_count via the Anthropic API", :vcr do
      snapshot = session.snapshots.create!(
        text: "Summary of a conversation about debugging a rails app",
        from_message_id: 1,
        to_message_id: 10,
        level: 1
      )

      described_class.perform_now(snapshot)

      expect(snapshot.reload.token_count).to be > 0
    end

    it "refines a PinnedMessage token_count via the Anthropic API", :vcr do
      message = session.messages.create!(
        message_type: "user_message", payload: {"content" => "Original pin source"}, timestamp: 1
      )
      pin = PinnedMessage.create!(message: message, display_text: "pinned excerpt")

      described_class.perform_now(pin)

      expect(pin.reload.token_count).to be > 0
    end

    it "discards the job when the record no longer exists" do
      expect(described_class.rescue_handlers).to include(
        satisfy { |handler| handler[0] == "ActiveRecord::RecordNotFound" }
      )
    end

    it "retries on Anthropic API errors" do
      expect(described_class.rescue_handlers).to include(
        satisfy { |handler| handler[0] == "Providers::Anthropic::Error" }
      )
    end
  end
end
