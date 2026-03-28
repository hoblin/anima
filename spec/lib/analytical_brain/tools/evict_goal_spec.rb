# frozen_string_literal: true

require "rails_helper"

RSpec.describe AnalyticalBrain::Tools::EvictGoal do
  describe ".tool_name" do
    it { expect(described_class.tool_name).to eq("evict_goal") }
  end

  describe ".schema" do
    it "returns a valid Anthropic tool schema" do
      schema = described_class.schema

      expect(schema[:name]).to eq("evict_goal")
      expect(schema[:description]).to be_present
      expect(schema[:input_schema][:required]).to eq(%w[goal_id])
      expect(schema[:input_schema][:properties]).to have_key(:goal_id)
    end
  end

  describe "#execute" do
    let(:session) { Session.create! }
    let(:tool) { described_class.new(main_session: session) }

    it "evicts a completed goal and sets evicted_at" do
      goal = session.goals.create!(description: "Done task", status: "completed", completed_at: 1.hour.ago)

      result = tool.execute({"goal_id" => goal.id})

      expect(result).to eq("Goal evicted: Done task (id: #{goal.id})")
      expect(goal.reload.evicted_at).to be_within(1.second).of(Time.current)
    end

    it "returns error for non-existent goal" do
      result = tool.execute({"goal_id" => 99999})

      expect(result).to eq({error: "Goal not found (id: 99999)"})
    end

    it "returns error when trying to evict an active goal" do
      goal = session.goals.create!(description: "Still working")

      result = tool.execute({"goal_id" => goal.id})

      expect(result).to eq({error: "Cannot evict active goal: Still working (id: #{goal.id})"})
      expect(goal.reload.evicted_at).to be_nil
    end

    it "returns error when goal is already evicted" do
      goal = session.goals.create!(
        description: "Old goal", status: "completed",
        completed_at: 2.hours.ago, evicted_at: 1.hour.ago
      )

      result = tool.execute({"goal_id" => goal.id})

      expect(result).to eq({error: "Goal already evicted: Old goal (id: #{goal.id})"})
    end

    it "does not evict goals from another session" do
      other_session = Session.create!
      other_goal = other_session.goals.create!(description: "Not mine", status: "completed", completed_at: 1.hour.ago)

      result = tool.execute({"goal_id" => other_goal.id})

      expect(result).to eq({error: "Goal not found (id: #{other_goal.id})"})
      expect(other_goal.reload.evicted_at).to be_nil
    end

    it "accepts context kwargs without error" do
      goal = session.goals.create!(description: "Context test", status: "completed", completed_at: 1.hour.ago)
      tool = described_class.new(main_session: session, extra_stuff: "ignored")

      result = tool.execute({"goal_id" => goal.id})

      expect(result).to include("Goal evicted:")
    end
  end
end
