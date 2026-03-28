# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::MarkGoalCompleted do
  let!(:parent_session) { Session.create! }
  let!(:child_session) { Session.create!(parent_session: parent_session, prompt: "sub-agent", name: "code-scout") }
  let!(:goal) { child_session.goals.create!(description: "Analyze the auth module") }

  subject(:tool) { described_class.new(session: child_session) }

  describe ".tool_name" do
    it "returns mark_goal_completed" do
      expect(described_class.tool_name).to eq("mark_goal_completed")
    end
  end

  describe ".description" do
    it "mentions task completion and parent delivery" do
      expect(described_class.description).to include("complete")
      expect(described_class.description).to include("parent")
    end
  end

  describe ".input_schema" do
    it "requires result as a string" do
      schema = described_class.input_schema
      expect(schema[:type]).to eq("object")
      expect(schema[:properties][:result][:type]).to eq("string")
      expect(schema[:required]).to contain_exactly("result")
    end
  end

  describe "#execute" do
    let(:input) { {"result" => "Found 3 N+1 queries in the orders controller."} }

    it "completes the sub-agent's active root goal" do
      tool.execute(input)

      expect(goal.reload).to be_completed
      expect(goal.completed_at).to be_present
    end

    it "cascades completion to sub-goals" do
      sub_goal = child_session.goals.create!(description: "Read models", parent_goal: goal)

      tool.execute(input)

      expect(sub_goal.reload).to be_completed
    end

    it "releases orphaned pinned messages" do
      message = child_session.messages.create!(
        message_type: "user_message",
        payload: {"content" => "test"},
        timestamp: 1
      )
      pin = message.pinned_messages.create!(display_text: "important context")
      goal.goal_pinned_messages.create!(pinned_message: pin)

      tool.execute(input)

      expect(PinnedMessage.find_by(id: pin.id)).to be_nil
    end

    it "routes the result to the parent session as a user message" do
      tool.execute(input)

      parent_msg = parent_session.messages.order(:id).last
      expect(parent_msg.message_type).to eq("user_message")
      expect(parent_msg.payload["content"]).to include("[sub-agent @code-scout]")
      expect(parent_msg.payload["content"]).to include("Found 3 N+1 queries")
    end

    it "enqueues AgentRequestJob for the parent session" do
      tool.execute(input)

      expect(AgentRequestJob).to have_been_enqueued.with(parent_session.id)
    end

    it "returns confirmation message" do
      result = tool.execute(input)

      expect(result).to include("Goal completed")
      expect(result).to include("Analyze the auth module")
      expect(result).to include("stop now")
    end

    it "uses fallback name when sub-agent has no name" do
      child_session.update!(name: nil)
      tool.execute(input)

      parent_msg = parent_session.messages.order(:id).last
      expect(parent_msg.payload["content"]).to include("[sub-agent @agent-#{child_session.id}]")
    end

    context "with blank result" do
      it "returns error" do
        result = tool.execute("result" => "  ")
        expect(result).to eq({error: "Result cannot be blank"})
      end

      it "does not complete the goal" do
        tool.execute("result" => "")
        expect(goal.reload).to be_active
      end
    end

    context "with no active goal" do
      before { goal.update!(status: "completed", completed_at: Time.current) }

      it "returns error" do
        result = tool.execute(input)
        expect(result).to eq({error: "No active goal found"})
      end
    end

    context "when parent session is processing" do
      before { parent_session.update!(processing: true) }

      it "emits a pending user message event instead of persisting directly" do
        expect {
          tool.execute(input)
        }.not_to change(parent_session.messages, :count)
      end
    end
  end
end
