# frozen_string_literal: true

require "rails_helper"

RSpec.describe AnalyticalBrain::Tools::SetGoal do
  describe ".tool_name" do
    it { expect(described_class.tool_name).to eq("set_goal") }
  end

  describe ".schema" do
    it "returns a valid Anthropic tool schema" do
      schema = described_class.schema

      expect(schema[:name]).to eq("set_goal")
      expect(schema[:description]).to be_present
      expect(schema[:input_schema][:required]).to eq(%w[description])
      expect(schema[:input_schema][:properties]).to have_key(:description)
      expect(schema[:input_schema][:properties]).to have_key(:parent_goal_id)
    end
  end

  describe "#execute" do
    let(:session) { Session.create! }
    let(:tool) { described_class.new(main_session: session) }

    it "creates a root goal and returns confirmation" do
      result = tool.execute({"description" => "Implement auth refactoring"})

      expect(result).to include("Goal created:")
      expect(result).to include("Implement auth refactoring")
      expect(result).to match(/id: \d+/)
      expect(session.goals.count).to eq(1)
      expect(session.goals.first.status).to eq("active")
    end

    it "creates a sub-goal under a parent" do
      parent = session.goals.create!(description: "Root goal")

      result = tool.execute({"description" => "Read code", "parent_goal_id" => parent.id})

      expect(result).to include("Sub-goal created:")
      expect(result).to include("Read code")
      sub = session.goals.where.not(id: parent.id).first
      expect(sub.parent_goal).to eq(parent)
    end

    it "returns error when description is blank" do
      result = tool.execute({"description" => ""})

      expect(result).to eq({error: "Description cannot be blank"})
      expect(session.goals.count).to eq(0)
    end

    it "returns error when description is whitespace only" do
      result = tool.execute({"description" => "   "})

      expect(result).to eq({error: "Description cannot be blank"})
    end

    it "returns error when parent goal is not root (too deep)" do
      root = session.goals.create!(description: "Root")
      child = session.goals.create!(description: "Child", parent_goal: root)

      result = tool.execute({"description" => "Too deep", "parent_goal_id" => child.id})

      expect(result).to be_a(Hash)
      expect(result[:error]).to include("cannot nest deeper")
    end

    it "returns error when parent goal belongs to another session" do
      other_session = Session.create!
      other_goal = other_session.goals.create!(description: "Other session goal")

      result = tool.execute({"description" => "Wrong parent", "parent_goal_id" => other_goal.id})

      expect(result).to be_a(Hash)
      expect(result[:error]).to include("must belong to the same session")
    end

    it "accepts context kwargs without error" do
      tool = described_class.new(main_session: session, extra_stuff: "ignored")
      result = tool.execute({"description" => "Test goal"})

      expect(result).to include("Goal created:")
    end
  end
end
