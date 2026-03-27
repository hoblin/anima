# frozen_string_literal: true

require "rails_helper"

RSpec.describe Mneme::Tools::AttachMessagesToGoals do
  let(:session) { Session.create! }

  describe ".tool_name" do
    it { expect(described_class.tool_name).to eq("attach_messages_to_goals") }
  end

  describe ".schema" do
    it "returns a valid Anthropic tool schema" do
      schema = described_class.schema

      expect(schema[:name]).to eq("attach_messages_to_goals")
      expect(schema[:description]).to be_present
      expect(schema[:input_schema][:required]).to include("message_ids", "goal_ids")
    end
  end

  describe "#execute" do
    let(:tool) { described_class.new(main_session: session) }
    let(:msg1) { session.messages.create!(message_type: "user_message", payload: {content: "Do this important thing"}, timestamp: 1) }
    let(:msg2) { session.messages.create!(message_type: "agent_message", payload: {content: "Understood, I will do it"}, timestamp: 2) }
    let(:goal) { session.goals.create!(description: "Important task") }

    it "creates pinned message records and join records" do
      expect {
        tool.execute("message_ids" => [msg1.id], "goal_ids" => [goal.id])
      }.to change(PinnedMessage, :count).by(1)
        .and change(GoalPinnedMessage, :count).by(1)
    end

    it "returns a confirmation with link count" do
      result = tool.execute("message_ids" => [msg1.id], "goal_ids" => [goal.id])
      expect(result).to eq("Pinned 1 message-goal links")
    end

    it "pins multiple messages to multiple goals" do
      goal2 = session.goals.create!(description: "Another task")

      result = tool.execute("message_ids" => [msg1.id, msg2.id], "goal_ids" => [goal.id, goal2.id])
      expect(result).to eq("Pinned 4 message-goal links")
      expect(PinnedMessage.count).to eq(2)
      expect(GoalPinnedMessage.count).to eq(4)
    end

    it "truncates display_text to 200 chars" do
      long_msg = session.messages.create!(
        message_type: "user_message",
        payload: {content: "x" * 300},
        timestamp: 3
      )

      tool.execute("message_ids" => [long_msg.id], "goal_ids" => [goal.id])
      pin = PinnedMessage.last
      expect(pin.display_text.length).to eq(200)
      expect(pin.display_text).to end_with("…")
    end

    it "falls back to message ID when content is empty" do
      empty_msg = session.messages.create!(message_type: "user_message", payload: {"content" => ""}, timestamp: 3)

      tool.execute("message_ids" => [empty_msg.id], "goal_ids" => [goal.id])
      pin = PinnedMessage.last
      expect(pin.display_text).to eq("message #{empty_msg.id}")
    end

    it "reuses existing PinnedMessage when pinning to additional goals" do
      tool.execute("message_ids" => [msg1.id], "goal_ids" => [goal.id])

      goal2 = session.goals.create!(description: "Second goal")
      expect {
        tool.execute("message_ids" => [msg1.id], "goal_ids" => [goal2.id])
      }.to change(PinnedMessage, :count).by(0)
        .and change(GoalPinnedMessage, :count).by(1)
    end

    it "is idempotent for duplicate pin+goal combos" do
      tool.execute("message_ids" => [msg1.id], "goal_ids" => [goal.id])

      expect {
        tool.execute("message_ids" => [msg1.id], "goal_ids" => [goal.id])
      }.to change(GoalPinnedMessage, :count).by(0)
    end

    it "returns error for empty message_ids" do
      result = tool.execute("message_ids" => [], "goal_ids" => [goal.id])
      expect(result).to eq("Error: message_ids cannot be empty")
    end

    it "returns error for empty goal_ids" do
      result = tool.execute("message_ids" => [msg1.id], "goal_ids" => [])
      expect(result).to eq("Error: goal_ids cannot be empty")
    end

    it "returns error when messages not found" do
      result = tool.execute("message_ids" => [999], "goal_ids" => [goal.id])
      expect(result).to include("Messages not found: 999")
    end

    it "returns error distinguishing completed goals from missing goals" do
      completed_goal = session.goals.create!(description: "Done", status: "completed", completed_at: Time.current)
      result = tool.execute("message_ids" => [msg1.id], "goal_ids" => [completed_goal.id])
      expect(result).to include("Goals already completed: #{completed_goal.id}")
    end

    it "returns error for non-existent goals" do
      result = tool.execute("message_ids" => [msg1.id], "goal_ids" => [888])
      expect(result).to include("Goals not found: 888")
    end

    it "returns combined errors for missing messages and goals" do
      result = tool.execute("message_ids" => [999], "goal_ids" => [888])
      expect(result).to include("Messages not found: 999")
      expect(result).to include("Goals not found: 888")
    end
  end
end
