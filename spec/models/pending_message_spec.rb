# frozen_string_literal: true

require "rails_helper"

RSpec.describe PendingMessage, type: :model do
  let(:session) { Session.create! }

  describe "validations" do
    it "requires content" do
      pm = PendingMessage.new(session: session, content: nil)
      expect(pm).not_to be_valid
    end

    it "requires a session" do
      pm = PendingMessage.new(content: "hello")
      expect(pm).not_to be_valid
    end

    it "is valid with session and content" do
      pm = PendingMessage.new(session: session, content: "hello")
      expect(pm).to be_valid
    end

    it "rejects invalid source_type" do
      pm = PendingMessage.new(session: session, content: "hi", source_type: "unknown")
      expect(pm).not_to be_valid
      expect(pm.errors[:source_type]).to be_present
    end

    it "requires source_name when source_type is subagent" do
      pm = PendingMessage.new(session: session, content: "hi", source_type: "subagent")
      expect(pm).not_to be_valid
      expect(pm.errors[:source_name]).to be_present
    end

    it "requires source_name when source_type is skill" do
      pm = PendingMessage.new(session: session, content: "hi", source_type: "skill")
      expect(pm).not_to be_valid
      expect(pm.errors[:source_name]).to be_present
    end

    it "requires source_name when source_type is workflow" do
      pm = PendingMessage.new(session: session, content: "hi", source_type: "workflow")
      expect(pm).not_to be_valid
      expect(pm.errors[:source_name]).to be_present
    end

    it "is valid as subagent with source_name" do
      pm = PendingMessage.new(session: session, content: "hi", source_type: "subagent", source_name: "scout")
      expect(pm).to be_valid
    end

    it "is valid as skill with source_name" do
      pm = PendingMessage.new(session: session, content: "hi", source_type: "skill", source_name: "gh-issue")
      expect(pm).to be_valid
    end

    it "is valid as workflow with source_name" do
      pm = PendingMessage.new(session: session, content: "hi", source_type: "workflow", source_name: "feature")
      expect(pm).to be_valid
    end
  end

  describe "#subagent?" do
    it "returns true when source_type is subagent" do
      pm = PendingMessage.new(session: session, content: "hi", source_type: "subagent")
      expect(pm).to be_subagent
    end

    it "returns false when source_type is user" do
      pm = PendingMessage.new(session: session, content: "hi", source_type: "user")
      expect(pm).not_to be_subagent
    end

    it "defaults to user" do
      pm = PendingMessage.new(session: session, content: "hi")
      expect(pm).not_to be_subagent
    end
  end

  describe "#phantom_pair?" do
    it "returns true for subagent messages" do
      pm = PendingMessage.new(source_type: "subagent")
      expect(pm).to be_phantom_pair
    end

    it "returns true for skill messages" do
      pm = PendingMessage.new(source_type: "skill")
      expect(pm).to be_phantom_pair
    end

    it "returns true for workflow messages" do
      pm = PendingMessage.new(source_type: "workflow")
      expect(pm).to be_phantom_pair
    end

    it "returns false for user messages" do
      pm = PendingMessage.new(source_type: "user")
      expect(pm).not_to be_phantom_pair
    end
  end

  describe "#display_content" do
    it "returns raw content for user messages" do
      pm = PendingMessage.new(session: session, content: "hello")
      expect(pm.display_content).to eq("hello")
    end

    it "returns attributed content for sub-agent messages" do
      pm = PendingMessage.new(session: session, content: "Found 3 bugs",
        source_type: "subagent", source_name: "loop-sleuth")
      expect(pm.display_content).to eq("[sub-agent loop-sleuth]: Found 3 bugs")
    end

    it "returns recall-labeled content for skill messages" do
      pm = PendingMessage.new(session: session, content: "Write thorough tests.",
        source_type: "skill", source_name: "testing")
      expect(pm.display_content).to eq("[recalled skill: testing]\nWrite thorough tests.")
    end

    it "returns recall-labeled content for workflow messages" do
      pm = PendingMessage.new(session: session, content: "Step 1: Create branch",
        source_type: "workflow", source_name: "feature")
      expect(pm.display_content).to eq("[recalled workflow: feature]\nStep 1: Create branch")
    end
  end

  describe "#to_llm_messages" do
    it "returns plain content string for user messages" do
      pm = session.pending_messages.create!(content: "hey there")
      expect(pm.to_llm_messages).to eq("hey there")
    end

    it "returns synthetic tool_use/tool_result pair for sub-agent messages" do
      pm = session.pending_messages.create!(
        content: "Here's my analysis",
        source_type: "subagent",
        source_name: "loop-sleuth"
      )

      messages = pm.to_llm_messages

      expect(messages).to be_an(Array)
      expect(messages.length).to eq(2)

      assistant_msg = messages[0]
      expect(assistant_msg[:role]).to eq("assistant")
      tool_use = assistant_msg[:content].first
      expect(tool_use[:type]).to eq("tool_use")
      expect(tool_use[:name]).to eq(PendingMessage::SUBAGENT_TOOL)
      expect(tool_use[:input]).to eq({from: "loop-sleuth"})
      expect(tool_use[:id]).to eq("subagent_message_#{pm.id}")

      user_msg = messages[1]
      expect(user_msg[:role]).to eq("user")
      tool_result = user_msg[:content].first
      expect(tool_result[:type]).to eq("tool_result")
      expect(tool_result[:tool_use_id]).to eq("subagent_message_#{pm.id}")
      expect(tool_result[:content]).to eq("Here's my analysis")
    end

    it "returns recall_skill phantom pair for skill messages" do
      pm = session.pending_messages.create!(
        content: "Write thorough tests.",
        source_type: "skill",
        source_name: "testing"
      )

      messages = pm.to_llm_messages
      expect(messages.length).to eq(2)

      tool_use = messages[0][:content].first
      expect(tool_use[:name]).to eq("recall_skill")
      expect(tool_use[:input]).to eq({skill: "testing"})
      expect(tool_use[:id]).to eq("recall_skill_#{pm.id}")

      tool_result = messages[1][:content].first
      expect(tool_result[:tool_use_id]).to eq("recall_skill_#{pm.id}")
      expect(tool_result[:content]).to eq("Write thorough tests.")
    end

    it "returns recall_workflow phantom pair for workflow messages" do
      pm = session.pending_messages.create!(
        content: "Step 1: Create branch",
        source_type: "workflow",
        source_name: "feature"
      )

      messages = pm.to_llm_messages
      expect(messages.length).to eq(2)

      tool_use = messages[0][:content].first
      expect(tool_use[:name]).to eq("recall_workflow")
      expect(tool_use[:input]).to eq({workflow: "feature"})

      tool_result = messages[1][:content].first
      expect(tool_result[:content]).to eq("Step 1: Create branch")
    end
  end

  describe "broadcasts" do
    it "broadcasts pending_message_created on create" do
      expect {
        session.pending_messages.create!(content: "waiting")
      }.to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("action" => "pending_message_created", "content" => "waiting"))
    end

    it "broadcasts pending_message_removed on destroy" do
      pm = session.pending_messages.create!(content: "waiting")

      expect {
        pm.destroy!
      }.to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("action" => "pending_message_removed", "pending_message_id" => pm.id))
    end
  end

  describe "dependent destroy" do
    it "is destroyed when session is destroyed" do
      session.pending_messages.create!(content: "orphan")

      expect { session.destroy! }.to change(PendingMessage, :count).by(-1)
    end
  end
end
