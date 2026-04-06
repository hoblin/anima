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

    it "overwrites the existing token_count with the freshly counted value", :vcr do
      event = session.messages.create!(
        message_type: "user_message",
        payload: {"content" => "Hello, Claude"},
        timestamp: 1,
        token_count: 9999
      )

      described_class.perform_now(event.id)

      expect(event.reload.token_count).to be_a(Integer)
      expect(event.reload.token_count).not_to eq(9999)
    end

    it "counts tool_call messages by serializing the payload as JSON", :vcr do
      event = session.messages.create!(
        message_type: "tool_call",
        payload: {"content" => "Calling bash", "tool_name" => "bash", "tool_input" => {"command" => "ls"}},
        tool_use_id: "toolu_count_tc",
        timestamp: 1
      )

      described_class.perform_now(event.id)

      expect(event.reload.token_count).to be > 0
    end

    it "counts tool_response messages by serializing the payload as JSON", :vcr do
      event = session.messages.create!(
        message_type: "tool_response",
        payload: {"content" => "file1\nfile2\nfile3", "tool_name" => "bash"},
        tool_use_id: "toolu_count_tr",
        timestamp: 1
      )

      described_class.perform_now(event.id)

      expect(event.reload.token_count).to be > 0
    end

    it "counts system_message content as a user message", :vcr do
      event = session.messages.create!(
        message_type: "system_message",
        payload: {"content" => "boot complete"},
        timestamp: 1
      )

      described_class.perform_now(event.id)

      expect(event.reload.token_count).to be > 0
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
