# frozen_string_literal: true

require "rails_helper"

RSpec.describe GenerateSessionNameJob do
  let(:session) { Session.create! }
  let(:valid_token) { "sk-ant-oat01-#{"a" * 68}" }

  before do
    allow(Rails.application.credentials).to receive(:dig)
      .with(:anthropic, :subscription_token)
      .and_return(valid_token)
  end

  describe "#perform" do
    it "generates a name from conversation context and saves it" do
      session.events.create!(event_type: "user_message", payload: {"content" => "Tell me about Ruby"}, timestamp: 1)
      session.events.create!(event_type: "agent_message", payload: {"content" => "Ruby is a programming language..."}, timestamp: 2)

      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .with(body: hash_including(
          "model" => Anima::Settings.fast_model,
          "max_tokens" => GenerateSessionNameJob::MAX_TOKENS
        ))
        .to_return(
          status: 200,
          body: {content: [{type: "text", text: "💎 Ruby Basics"}], stop_reason: "end_turn"}.to_json,
          headers: {"content-type" => "application/json"}
        )

      described_class.perform_now(session.id)

      expect(session.reload.name).to eq("💎 Ruby Basics")
    end

    it "overwrites existing names with a fresh one" do
      session.update!(name: "Old Name")
      session.events.create!(event_type: "user_message", payload: {"content" => "New topic"}, timestamp: 1)

      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(
          status: 200,
          body: {content: [{type: "text", text: "🆕 New Topic"}], stop_reason: "end_turn"}.to_json,
          headers: {"content-type" => "application/json"}
        )

      described_class.perform_now(session.id)

      expect(session.reload.name).to eq("🆕 New Topic")
    end

    it "skips sessions with no conversation events" do
      described_class.perform_now(session.id)

      expect(WebMock).not_to have_requested(:post, "https://api.anthropic.com/v1/messages")
      expect(session.reload.name).to be_nil
    end

    it "strips whitespace from the generated name" do
      session.events.create!(event_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(
          status: 200,
          body: {content: [{type: "text", text: "  🎉 Chat Fun  \n"}], stop_reason: "end_turn"}.to_json,
          headers: {"content-type" => "application/json"}
        )

      described_class.perform_now(session.id)

      expect(session.reload.name).to eq("🎉 Chat Fun")
    end

    it "truncates names longer than 255 characters" do
      session.events.create!(event_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

      long_name = "🔧 #{"A" * 260}"
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(
          status: 200,
          body: {content: [{type: "text", text: long_name}], stop_reason: "end_turn"}.to_json,
          headers: {"content-type" => "application/json"}
        )

      described_class.perform_now(session.id)

      expect(session.reload.name.length).to be <= 255
    end

    it "limits context to MAX_CONTEXT_EVENTS events" do
      10.times do |i|
        session.events.create!(
          event_type: (i.even? ? "user_message" : "agent_message"),
          payload: {"content" => "Message #{i}"},
          timestamp: i + 1
        )
      end

      captured_messages = nil
      allow(LLM::Client).to receive(:new).and_wrap_original do |original, **args|
        client = original.call(**args)
        allow(client).to receive(:chat) do |messages|
          captured_messages = messages
          "📝 Long Chat"
        end
        client
      end

      described_class.perform_now(session.id)

      context = captured_messages.first[:content]
      event_count = context.scan(/(?:User|Assistant):/).length
      expect(event_count).to eq(GenerateSessionNameJob::MAX_CONTEXT_EVENTS)
    end

    it "excludes tool events from context" do
      session.events.create!(event_type: "user_message", payload: {"content" => "Do something"}, timestamp: 1)
      session.events.create!(
        event_type: "tool_call",
        payload: {"content" => "Calling bash", "tool_name" => "bash", "tool_use_id" => "t1"},
        timestamp: 2
      )
      session.events.create!(event_type: "agent_message", payload: {"content" => "Done!"}, timestamp: 3)

      captured_messages = nil
      allow(LLM::Client).to receive(:new).and_wrap_original do |original, **args|
        client = original.call(**args)
        allow(client).to receive(:chat) do |messages|
          captured_messages = messages
          "🔨 Task Done"
        end
        client
      end

      described_class.perform_now(session.id)

      context = captured_messages.first[:content]
      expect(context).not_to include("Calling bash")
      expect(context).to include("Do something")
      expect(context).to include("Done!")
    end

    it "discards the job if the session no longer exists" do
      expect {
        described_class.perform_now(999_999)
      }.not_to raise_error
    end

    it "retries on Anthropic transient errors" do
      expect(described_class.rescue_handlers).to include(
        satisfy { |handler| handler[0] == "Providers::Anthropic::TransientError" }
      )
    end

    it "discards on Anthropic authentication errors" do
      expect(described_class.rescue_handlers).to include(
        satisfy { |handler| handler[0] == "Providers::Anthropic::AuthenticationError" }
      )
    end
  end
end
