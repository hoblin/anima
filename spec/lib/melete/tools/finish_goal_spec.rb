# frozen_string_literal: true

require "rails_helper"

RSpec.describe Melete::Tools::FinishGoal do
  describe ".tool_name" do
    it { expect(described_class.tool_name).to eq("finish_goal") }
  end

  describe ".schema" do
    it "returns a valid Anthropic tool schema" do
      schema = described_class.schema

      expect(schema[:name]).to eq("finish_goal")
      expect(schema[:description]).to be_present
      expect(schema[:input_schema][:required]).to eq(%w[goal_id])
      expect(schema[:input_schema][:properties]).to have_key(:goal_id)
    end
  end

  describe "#execute" do
    let(:session) { Session.create! }
    let(:tool) { described_class.new(main_session: session) }

    it "marks an active goal as completed" do
      goal = session.goals.create!(description: "Write tests")

      result = tool.execute({"goal_id" => goal.id})

      expect(result).to eq("Goal completed: Write tests (id: #{goal.id})")
      goal.reload
      expect(goal.status).to eq("completed")
      expect(goal.completed_at).to be_within(1.second).of(Time.current)
    end

    it "enqueues a goal PendingMessage on the main session" do
      goal = session.goals.create!(description: "Write tests")

      expect {
        tool.execute({"goal_id" => goal.id})
      }.to change(session.pending_messages, :count).by(1)

      pm = session.pending_messages.last
      expect(pm.source_type).to eq("goal")
      expect(pm.source_name).to eq(goal.id.to_s)
      expect(pm.content).to include("Goal completed:")
    end

    it "marks a sub-goal as completed while parent stays active" do
      root = session.goals.create!(description: "Root goal")
      sub = session.goals.create!(description: "Sub-step", parent_goal: root)

      result = tool.execute({"goal_id" => sub.id})

      expect(result).to eq("Goal completed: Sub-step (id: #{sub.id})")
      expect(sub.reload.status).to eq("completed")
      expect(root.reload.status).to eq("active")
    end

    it "returns error for non-existent goal" do
      result = tool.execute({"goal_id" => 99999})

      expect(result).to eq({error: "Goal not found (id: 99999)"})
    end

    it "returns error for already completed goal" do
      goal = session.goals.create!(description: "Done already", status: "completed", completed_at: 1.hour.ago)

      result = tool.execute({"goal_id" => goal.id})

      expect(result).to eq({error: "Goal already completed: Done already (id: #{goal.id})"})
    end

    it "does not complete goals from another session" do
      other_session = Session.create!
      other_goal = other_session.goals.create!(description: "Not mine")

      result = tool.execute({"goal_id" => other_goal.id})

      expect(result).to eq({error: "Goal not found (id: #{other_goal.id})"})
      expect(other_goal.reload.status).to eq("active")
    end

    it "accepts context kwargs without error" do
      goal = session.goals.create!(description: "Context test")
      tool = described_class.new(main_session: session, extra_stuff: "ignored")

      result = tool.execute({"goal_id" => goal.id})

      expect(result).to include("Goal completed:")
    end

    context "completion cascade" do
      it "cascades completion to all active sub-goals when finishing a root goal" do
        root = session.goals.create!(description: "Root goal")
        sub_a = session.goals.create!(description: "Sub A", parent_goal: root)
        sub_b = session.goals.create!(description: "Sub B", parent_goal: root)

        tool.execute({"goal_id" => root.id})

        expect(sub_a.reload.status).to eq("completed")
        expect(sub_a.completed_at).to be_within(1.second).of(Time.current)
        expect(sub_b.reload.status).to eq("completed")
        expect(sub_b.completed_at).to be_within(1.second).of(Time.current)
      end

      it "only cascades to active sub-goals, leaving already completed ones unchanged" do
        root = session.goals.create!(description: "Root goal")
        completed_sub = session.goals.create!(
          description: "Already done", parent_goal: root,
          status: "completed", completed_at: 1.hour.ago
        )
        active_sub = session.goals.create!(description: "Still active", parent_goal: root)

        tool.execute({"goal_id" => root.id})

        expect(active_sub.reload.status).to eq("completed")
        expect(completed_sub.reload.completed_at).to be_within(1.second).of(1.hour.ago)
      end

      it "does not cascade when finishing a sub-goal" do
        root = session.goals.create!(description: "Root goal")
        sub = session.goals.create!(description: "Sub-goal", parent_goal: root)

        tool.execute({"goal_id" => sub.id})

        expect(sub.reload.status).to eq("completed")
        expect(root.reload.status).to eq("active")
      end
    end

    context "pinned message cleanup" do
      let(:msg) { session.messages.create!(message_type: "user_message", payload: {content: "critical"}, timestamp: 1) }

      it "releases orphaned pins when completing a goal" do
        goal = session.goals.create!(description: "Only goal")
        pin = PinnedMessage.create!(message: msg, display_text: "critical")
        GoalPinnedMessage.create!(goal: goal, pinned_message: pin)

        result = tool.execute({"goal_id" => goal.id})

        expect(result).to include("released 1 orphaned pins")
        expect(PinnedMessage.find_by(id: pin.id)).to be_nil
      end

      it "keeps pins alive when another active goal references them" do
        goal_a = session.goals.create!(description: "First goal")
        goal_b = session.goals.create!(description: "Second goal")
        pin = PinnedMessage.create!(message: msg, display_text: "critical")
        GoalPinnedMessage.create!(goal: goal_a, pinned_message: pin)
        GoalPinnedMessage.create!(goal: goal_b, pinned_message: pin)

        result = tool.execute({"goal_id" => goal_a.id})

        expect(result).not_to include("released")
        expect(PinnedMessage.find_by(id: pin.id)).to be_present
      end

      it "releases pins from cascaded sub-goals too" do
        root = session.goals.create!(description: "Root")
        sub = session.goals.create!(description: "Sub", parent_goal: root)
        pin = PinnedMessage.create!(message: msg, display_text: "critical")
        GoalPinnedMessage.create!(goal: sub, pinned_message: pin)

        result = tool.execute({"goal_id" => root.id})

        expect(result).to include("released 1 orphaned pins")
        expect(PinnedMessage.find_by(id: pin.id)).to be_nil
      end
    end
  end
end
