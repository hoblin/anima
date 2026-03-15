# frozen_string_literal: true

require "rails_helper"

RSpec.describe AnalyticalBrain::Tools::FinishGoal do
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
      expect(goal.completed_at).to be_present
    end

    it "returns error for non-existent goal" do
      result = tool.execute({"goal_id" => 99999})

      expect(result).to eq({error: "Goal not found (id: 99999)"})
    end

    it "returns error for already completed goal" do
      goal = session.goals.create!(description: "Done already", status: "completed", completed_at: 1.hour.ago)

      result = tool.execute({"goal_id" => goal.id})

      expect(result).to eq({error: "Goal already completed (id: #{goal.id})"})
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
  end
end
