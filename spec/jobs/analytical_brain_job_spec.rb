# frozen_string_literal: true

require "rails_helper"

RSpec.describe AnalyticalBrainJob do
  let(:session) { Session.create! }
  let(:valid_token) { "sk-ant-oat01-#{"a" * 68}" }

  before do
    allow(Rails.application.credentials).to receive(:dig)
      .with(:anthropic, :subscription_token)
      .and_return(valid_token)
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
      session.events.create!(event_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)
      session.events.create!(event_type: "agent_message", payload: {"content" => "Hi!"}, timestamp: 2)

      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(
          status: 200,
          body: {
            content: [{type: "text", text: "All good"}],
            stop_reason: "end_turn"
          }.to_json,
          headers: {"content-type" => "application/json"}
        )

      expect { described_class.perform_now(session.id) }.not_to raise_error
    end

    it "renames the session when the LLM calls rename_session" do
      session.events.create!(event_type: "user_message", payload: {"content" => "Tell me about Rails"}, timestamp: 1)
      session.events.create!(event_type: "agent_message", payload: {"content" => "Rails is a framework..."}, timestamp: 2)

      call_count = 0
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return do
          call_count += 1
          if call_count == 1
            {
              status: 200,
              body: {
                content: [{
                  type: "tool_use",
                  id: "toolu_rename_1",
                  name: "rename_session",
                  input: {"emoji" => "🚂", "name" => "Rails Talk"}
                }],
                stop_reason: "tool_use"
              }.to_json,
              headers: {"content-type" => "application/json"}
            }
          else
            {
              status: 200,
              body: {
                content: [{type: "text", text: "Done"}],
                stop_reason: "end_turn"
              }.to_json,
              headers: {"content-type" => "application/json"}
            }
          end
        end

      described_class.perform_now(session.id)

      expect(session.reload.name).to eq("🚂 Rails Talk")
    end

    it "does not persist analytical brain events to the database" do
      session.events.create!(event_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)
      session.events.create!(event_type: "agent_message", payload: {"content" => "Hi!"}, timestamp: 2)

      call_count = 0
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return do
          call_count += 1
          if call_count == 1
            {
              status: 200,
              body: {
                content: [{
                  type: "tool_use",
                  id: "toolu_ready_1",
                  name: "everything_is_ready",
                  input: {}
                }],
                stop_reason: "tool_use"
              }.to_json,
              headers: {"content-type" => "application/json"}
            }
          else
            {
              status: 200,
              body: {
                content: [{type: "text", text: "All good"}],
                stop_reason: "end_turn"
              }.to_json,
              headers: {"content-type" => "application/json"}
            }
          end
        end

      expect { described_class.perform_now(session.id) }
        .not_to change(Event, :count)
    end

    it "discards the job if the session no longer exists" do
      expect { described_class.perform_now(999_999) }.not_to raise_error
    end

    it "does nothing for sessions with no events" do
      expect { described_class.perform_now(session.id) }.not_to raise_error
      expect(WebMock).not_to have_requested(:post, "https://api.anthropic.com/v1/messages")
    end
  end
end
