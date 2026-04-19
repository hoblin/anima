# frozen_string_literal: true

require "rails_helper"

RSpec.describe Message do
  let(:session) { create(:session) }

  describe "validations" do
    it "rejects a message_type outside the allowed list" do
      message = build(:message, :user_message, message_type: "invalid", session: session)

      expect(message).not_to be_valid
      expect(message.errors[:message_type]).to include("is not included in the list")
    end

    it "requires a tool_use_id for tool_call and tool_response messages" do
      %w[tool_call tool_response].each do |type|
        message = build(:message, session: session, message_type: type, payload: {"content" => "x"})
        expect(message).not_to be_valid, "expected #{type} to need tool_use_id"
        expect(message.errors[:tool_use_id]).to include("can't be blank")
      end
    end

    it "does not require a tool_use_id for conversation messages" do
      %w[system_message user_message agent_message].each do |type|
        message = build(:message, session: session, message_type: type, payload: {"content" => "hi"})
        expect(message).to be_valid, "expected #{type} to be valid without tool_use_id"
      end
    end
  end

  describe ".llm_messages" do
    it "returns only user_message and agent_message rows" do
      create(:message, :user_message, session: session)
      create(:message, :agent_message, session: session)
      create(:message, :system_message, session: session)
      create(:message, :bash_tool_call, session: session)

      expect(Message.llm_messages.pluck(:message_type)).to match_array(%w[user_message agent_message])
    end
  end

  describe "token_count seeding" do
    it "seeds from the local estimate of tokenization_text on create" do
      message = create(:message, :user_message, session: session, payload: {"content" => "hello world"})

      # "hello world" = 11 bytes, ceil(11/4) = 3
      expect(message.token_count).to eq(3)
    end

    it "respects an explicit token_count passed in by the caller" do
      message = create(:message, :user_message, session: session, token_count: 42)

      expect(message.token_count).to eq(42)
    end

    it "seeds tool_call messages from the full payload JSON (not just content)" do
      message = create(:message, :bash_tool_call, session: session)

      expect(message.token_count).to eq((message.payload.to_json.bytesize / 4.0).ceil)
    end
  end

  describe "#api_role" do
    it "maps user_message to user" do
      expect(build(:message, :user_message).api_role).to eq("user")
    end

    it "maps agent_message to assistant" do
      expect(build(:message, :agent_message).api_role).to eq("assistant")
    end

    it "raises KeyError for non-LLM types (callers must guard)" do
      expect { build(:message, :bash_tool_call).api_role }.to raise_error(KeyError)
    end
  end

  describe "#tokenization_text" do
    it "returns payload content for conversation messages" do
      message = build(:message, :user_message, payload: {"content" => "hello world"})
      expect(message.tokenization_text).to eq("hello world")
    end

    it "serialises the full payload as JSON for tool messages (so tool_name/tool_input count)" do
      message = build(:message, :bash_tool_call)
      expect(message.tokenization_text).to eq(message.payload.to_json)
    end
  end

  describe "#conversation_or_think?" do
    it "is true for user/agent/system messages and the think tool_call, false elsewhere" do
      expect(Message.new(message_type: "user_message", payload: {})).to be_conversation_or_think
      expect(Message.new(message_type: "agent_message", payload: {})).to be_conversation_or_think
      expect(Message.new(message_type: "system_message", payload: {})).to be_conversation_or_think
      expect(Message.new(message_type: "tool_call", payload: {"tool_name" => "think"})).to be_conversation_or_think

      expect(Message.new(message_type: "tool_call", payload: {"tool_name" => "bash"})).not_to be_conversation_or_think
      expect(Message.new(message_type: "tool_response", payload: {"tool_name" => "bash"})).not_to be_conversation_or_think
    end
  end

  describe "after_create callback" do
    %w[user_message agent_message system_message tool_call tool_response].each do |type|
      it "enqueues CountTokensJob for #{type}" do
        trait = if type == "tool_call"
          :bash_tool_call
        else
          (type == "tool_response") ? :bash_tool_response : :"#{type}"
        end

        expect { create(:message, trait, session: session) }.to have_enqueued_job(CountTokensJob)
      end
    end
  end
end
