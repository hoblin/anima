# frozen_string_literal: true

require "rails_helper"

RSpec.describe Message do
  let(:session) { Session.create! }

  describe "validations" do
    it "requires message_type" do
      event = Message.new(session: session, payload: {content: "hi"}, timestamp: 1)
      event.message_type = nil
      expect(event).not_to be_valid
      expect(event.errors[:message_type]).to include("can't be blank")
    end

    it "rejects invalid message_type" do
      event = Message.new(session: session, message_type: "invalid", payload: {content: "hi"}, timestamp: 1)
      expect(event).not_to be_valid
      expect(event.errors[:message_type]).to include("is not included in the list")
    end

    it "requires payload" do
      event = Message.new(session: session, message_type: "user_message", timestamp: 1)
      event.payload = nil
      expect(event).not_to be_valid
      expect(event.errors[:payload]).to include("can't be blank")
    end

    it "requires timestamp" do
      event = Message.new(session: session, message_type: "user_message", payload: {content: "hi"})
      event.timestamp = nil
      expect(event).not_to be_valid
      expect(event.errors[:timestamp]).to include("can't be blank")
    end

    it "requires session" do
      event = Message.new(message_type: "user_message", payload: {content: "hi"}, timestamp: 1)
      expect(event).not_to be_valid
    end

    it "requires tool_use_id for tool_call events" do
      event = Message.new(session: session, message_type: "tool_call", payload: {content: "run"}, timestamp: 1)
      expect(event).not_to be_valid
      expect(event.errors[:tool_use_id]).to include("can't be blank")
    end

    it "requires tool_use_id for tool_response events" do
      event = Message.new(session: session, message_type: "tool_response", payload: {content: "ok"}, timestamp: 1)
      expect(event).not_to be_valid
      expect(event.errors[:tool_use_id]).to include("can't be blank")
    end

    it "does not require tool_use_id for non-tool events" do
      %w[system_message user_message agent_message].each do |type|
        event = Message.new(session: session, message_type: type, payload: {content: "hi"}, timestamp: 1)
        expect(event).to be_valid, "expected #{type} to be valid without tool_use_id"
      end
    end

    it "is valid with all required attributes" do
      event = Message.new(session: session, message_type: "user_message", payload: {content: "hi"}, timestamp: 1)
      expect(event).to be_valid
    end
  end

  describe ".llm_messages" do
    it "returns only user_message and agent_message events" do
      session.messages.create!(message_type: "user_message", payload: {content: "hi"}, timestamp: 1)
      session.messages.create!(message_type: "agent_message", payload: {content: "hello"}, timestamp: 2)
      session.messages.create!(message_type: "system_message", payload: {content: "boot"}, timestamp: 3)
      session.messages.create!(message_type: "tool_call", payload: {content: "run", tool_name: "bash", tool_input: {}}, tool_use_id: "toolu_test1", timestamp: 4)

      expect(Message.llm_messages.pluck(:message_type)).to match_array(%w[user_message agent_message])
    end
  end

  describe "associations" do
    it "belongs to a session" do
      event = session.messages.create!(message_type: "user_message", payload: {content: "hi"}, timestamp: 1)
      expect(event.session).to eq(session)
    end
  end

  describe "token_count seeding" do
    it "is set to the local estimate before validation on create" do
      event = session.messages.create!(message_type: "user_message", payload: {"content" => "hello world"}, timestamp: 1)

      # "hello world" = 11 bytes, 11/4 = 2.75, ceil = 3
      expect(event.token_count).to eq(3)
    end

    it "respects an explicit positive value passed by the caller" do
      event = session.messages.create!(message_type: "user_message", payload: {"content" => "hi"}, timestamp: 1, token_count: 42)

      expect(event.token_count).to eq(42)
    end

    it "seeds tool_call messages from full payload JSON" do
      event = session.messages.create!(
        message_type: "tool_call",
        payload: {"content" => "calling", "tool_name" => "bash", "tool_input" => {"command" => "ls"}},
        tool_use_id: "toolu_seed1",
        timestamp: 1
      )

      expected = (event.payload.to_json.bytesize / 4.0).ceil
      expect(event.token_count).to eq(expected)
    end
  end

  describe "#api_role" do
    it "maps user_message to user" do
      event = session.messages.create!(message_type: "user_message", payload: {content: "hi"}, timestamp: 1)
      expect(event.api_role).to eq("user")
    end

    it "maps agent_message to assistant" do
      event = session.messages.create!(message_type: "agent_message", payload: {content: "hi"}, timestamp: 1)
      expect(event.api_role).to eq("assistant")
    end

    it "raises KeyError for non-LLM event types" do
      event = session.messages.create!(message_type: "tool_call", payload: {content: "run"}, tool_use_id: "toolu_test1", timestamp: 1)
      expect { event.api_role }.to raise_error(KeyError)
    end
  end

  describe "#tokenization_text" do
    it "returns the content string for conversation messages" do
      event = session.messages.create!(
        message_type: "user_message", payload: {"content" => "hello world"}, timestamp: 1
      )

      expect(event.tokenization_text).to eq("hello world")
    end

    it "serializes the full payload as JSON for tool_call messages" do
      event = session.messages.create!(
        message_type: "tool_call",
        payload: {"content" => "calling", "tool_name" => "bash", "tool_input" => {"command" => "ls"}},
        tool_use_id: "toolu_tokenization_tc",
        timestamp: 1
      )

      expect(event.tokenization_text).to eq(event.payload.to_json)
    end

    it "serializes the full payload as JSON for tool_response messages" do
      event = session.messages.create!(
        message_type: "tool_response",
        payload: {"content" => "ok"},
        tool_use_id: "toolu_tokenization_tr",
        timestamp: 1
      )

      expect(event.tokenization_text).to eq(event.payload.to_json)
    end

    it "returns an empty string for nil content on conversation messages" do
      event = session.messages.new(
        message_type: "user_message", payload: {"content" => nil}, timestamp: 1
      )

      expect(event.tokenization_text).to eq("")
    end
  end

  describe "#conversation_or_think?" do
    it "returns true for user_message" do
      expect(Message.new(message_type: "user_message", payload: {})).to be_conversation_or_think
    end

    it "returns true for agent_message" do
      expect(Message.new(message_type: "agent_message", payload: {})).to be_conversation_or_think
    end

    it "returns true for system_message" do
      expect(Message.new(message_type: "system_message", payload: {})).to be_conversation_or_think
    end

    it "returns true for think tool_call" do
      event = Message.new(message_type: "tool_call", payload: {"tool_name" => "think"})
      expect(event).to be_conversation_or_think
    end

    it "returns false for non-think tool_call" do
      event = Message.new(message_type: "tool_call", payload: {"tool_name" => "bash"})
      expect(event).not_to be_conversation_or_think
    end

    it "returns false for tool_response" do
      event = Message.new(message_type: "tool_response", payload: {"tool_name" => "bash"})
      expect(event).not_to be_conversation_or_think
    end
  end

  describe "after_create callback" do
    %w[user_message agent_message system_message].each do |type|
      it "enqueues CountTokensJob for #{type}" do
        expect {
          session.messages.create!(message_type: type, payload: {content: "hi"}, timestamp: 1)
        }.to have_enqueued_job(CountTokensJob)
      end
    end

    it "enqueues CountTokensJob for tool_call" do
      expect {
        session.messages.create!(
          message_type: "tool_call",
          payload: {content: "running", tool_name: "bash", tool_input: {}},
          tool_use_id: "toolu_after_create",
          timestamp: 1
        )
      }.to have_enqueued_job(CountTokensJob)
    end

    it "enqueues CountTokensJob for tool_response" do
      expect {
        session.messages.create!(
          message_type: "tool_response",
          payload: {content: "ok"},
          tool_use_id: "toolu_after_create_resp",
          timestamp: 1
        )
      }.to have_enqueued_job(CountTokensJob)
    end
  end
end
