# frozen_string_literal: true

require "rails_helper"

RSpec.describe CountEventTokensJob do
  let(:session) { Session.create! }
  let(:valid_token) { "sk-ant-oat01-#{"a" * 68}" }

  before do
    allow(Rails.application.credentials).to receive(:dig)
      .with(:anthropic, :subscription_token)
      .and_return(valid_token)
  end

  describe "#perform" do
    it "counts tokens via the Anthropic API and updates the event" do
      event = session.events.create!(
        event_type: "user_message",
        payload: {"content" => "Hello, Claude"},
        timestamp: 1
      )

      stub_request(:post, "https://api.anthropic.com/v1/messages/count_tokens")
        .with(body: hash_including(
          "model" => Anima::Settings.model,
          "messages" => [{"role" => "user", "content" => "Hello, Claude"}]
        ))
        .to_return(
          status: 200,
          body: {input_tokens: 12}.to_json,
          headers: {"content-type" => "application/json"}
        )

      described_class.perform_now(event.id)

      expect(event.reload.token_count).to eq(12)
    end

    it "maps agent_message events to assistant role" do
      event = session.events.create!(
        event_type: "agent_message",
        payload: {"content" => "Hi there"},
        timestamp: 1
      )

      stub_request(:post, "https://api.anthropic.com/v1/messages/count_tokens")
        .with(body: hash_including(
          "messages" => [{"role" => "assistant", "content" => "Hi there"}]
        ))
        .to_return(
          status: 200,
          body: {input_tokens: 8}.to_json,
          headers: {"content-type" => "application/json"}
        )

      described_class.perform_now(event.id)

      expect(event.reload.token_count).to eq(8)
    end

    it "skips events that already have a token count" do
      event = session.events.create!(
        event_type: "user_message",
        payload: {"content" => "Hello"},
        timestamp: 1,
        token_count: 10
      )

      described_class.perform_now(event.id)

      # No API call should be made
      expect(WebMock).not_to have_requested(:post, "https://api.anthropic.com/v1/messages/count_tokens")
      expect(event.reload.token_count).to eq(10)
    end

    it "discards the job if the event no longer exists" do
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
