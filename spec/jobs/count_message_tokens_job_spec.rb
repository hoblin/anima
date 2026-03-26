# frozen_string_literal: true

require "rails_helper"

RSpec.describe CountMessageTokensJob do
  let(:session) { Session.create! }

  describe "#perform" do
    it "counts tokens via the Anthropic API and updates the message", :vcr do
      event = session.messages.create!(
        message_type: "user_message",
        payload: {"content" => "Hello, Claude"},
        timestamp: 1
      )

      described_class.perform_now(event.id)

      expect(event.reload.token_count).to be_a(Integer)
      expect(event.reload.token_count).to be > 0
    end

    it "maps agent_message to assistant role", :vcr do
      event = session.messages.create!(
        message_type: "agent_message",
        payload: {"content" => "Hi there"},
        timestamp: 1
      )

      described_class.perform_now(event.id)

      expect(event.reload.token_count).to be_a(Integer)
      expect(event.reload.token_count).to be > 0
    end

    it "skips messages that already have a token count", :vcr do
      event = session.messages.create!(
        message_type: "user_message",
        payload: {"content" => "Hello"},
        timestamp: 1,
        token_count: 10
      )

      described_class.perform_now(event.id)

      expect(event.reload.token_count).to eq(10)
    end

    it "discards the job if the message no longer exists" do
      expect {
        described_class.perform_now(999_999)
      }.not_to raise_error
    end

    it "retries on Anthropic API errors" do
      expect(described_class.rescue_handlers).to include(
        satisfy { |handler| handler[0] == "Providers::Anthropic::Error" }
      )
    end
  end
end
