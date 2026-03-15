# frozen_string_literal: true

require "rails_helper"

RSpec.describe AnalyticalBrain::Tools::UpdateGoal do
  describe ".tool_name" do
    it { expect(described_class.tool_name).to eq("update_goal") }
  end

  describe ".schema" do
    it "returns a valid Anthropic tool schema" do
      schema = described_class.schema

      expect(schema[:name]).to eq("update_goal")
      expect(schema[:description]).to be_present
      expect(schema[:input_schema][:required]).to eq(%w[goal_id description])
      expect(schema[:input_schema][:properties]).to have_key(:goal_id)
      expect(schema[:input_schema][:properties]).to have_key(:description)
    end
  end

  describe "#execute" do
    let(:session) { Session.create! }
    let(:tool) { described_class.new(main_session: session) }

    it "updates a goal's description" do
      goal = session.goals.create!(description: "Implement auth")

      result = tool.execute({"goal_id" => goal.id, "description" => "Implement OAuth2 middleware"})

      expect(result).to eq("Goal updated: Implement OAuth2 middleware (id: #{goal.id})")
      expect(goal.reload.description).to eq("Implement OAuth2 middleware")
    end

    it "updates a sub-goal's description" do
      root = session.goals.create!(description: "Root goal")
      sub = session.goals.create!(description: "Read code", parent_goal: root)

      result = tool.execute({"goal_id" => sub.id, "description" => "Read auth middleware code"})

      expect(result).to include("Goal updated:")
      expect(sub.reload.description).to eq("Read auth middleware code")
    end

    it "strips whitespace from description" do
      goal = session.goals.create!(description: "Old description")

      tool.execute({"goal_id" => goal.id, "description" => "  New description  "})

      expect(goal.reload.description).to eq("New description")
    end

    it "returns error when description is blank" do
      goal = session.goals.create!(description: "Some goal")

      result = tool.execute({"goal_id" => goal.id, "description" => ""})

      expect(result).to eq({error: "Description cannot be blank"})
      expect(goal.reload.description).to eq("Some goal")
    end

    it "returns error when description is whitespace only" do
      goal = session.goals.create!(description: "Some goal")

      result = tool.execute({"goal_id" => goal.id, "description" => "   "})

      expect(result).to eq({error: "Description cannot be blank"})
    end

    it "returns error for non-existent goal" do
      result = tool.execute({"goal_id" => 99999, "description" => "New desc"})

      expect(result).to eq({error: "Goal not found (id: 99999)"})
    end

    it "returns error for completed goal" do
      goal = session.goals.create!(description: "Done", status: "completed", completed_at: 1.hour.ago)

      result = tool.execute({"goal_id" => goal.id, "description" => "Updated"})

      expect(result).to eq({error: "Cannot update completed goal: Done (id: #{goal.id})"})
      expect(goal.reload.description).to eq("Done")
    end

    it "does not update goals from another session" do
      other_session = Session.create!
      other_goal = other_session.goals.create!(description: "Not mine")

      result = tool.execute({"goal_id" => other_goal.id, "description" => "Hijacked"})

      expect(result).to eq({error: "Goal not found (id: #{other_goal.id})"})
      expect(other_goal.reload.description).to eq("Not mine")
    end

    it "accepts context kwargs without error" do
      goal = session.goals.create!(description: "Test")
      tool = described_class.new(main_session: session, extra_stuff: "ignored")

      result = tool.execute({"goal_id" => goal.id, "description" => "Updated test"})

      expect(result).to include("Goal updated:")
    end
  end
end
