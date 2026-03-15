# frozen_string_literal: true

require "rails_helper"

RSpec.describe AnalyticalBrain::Tools::DeactivateSkill do
  before { Skills::Registry.reload! }

  describe ".tool_name" do
    it { expect(described_class.tool_name).to eq("deactivate_skill") }
  end

  describe ".schema" do
    it "returns a valid Anthropic tool schema" do
      schema = described_class.schema

      expect(schema[:name]).to eq("deactivate_skill")
      expect(schema[:description]).to be_present
      expect(schema[:input_schema][:required]).to eq(%w[name])
      expect(schema[:input_schema][:properties]).to have_key(:name)
    end
  end

  describe "#execute" do
    let(:session) { Session.create! }
    let(:tool) { described_class.new(main_session: session) }

    before do
      session.activate_skill("gh-issue")
    end

    it "deactivates a skill and returns confirmation" do
      result = tool.execute({"name" => "gh-issue"})

      expect(result).to eq("Deactivated skill: gh-issue")
      expect(session.reload.active_skills).not_to include("gh-issue")
    end

    it "is safe to call for a skill that is not active" do
      result = tool.execute({"name" => "not-active"})

      expect(result).to eq("Deactivated skill: not-active")
    end

    it "returns error when name is blank" do
      result = tool.execute({"name" => ""})

      expect(result).to eq({error: "Skill name cannot be blank"})
    end

    it "accepts context kwargs without error" do
      tool = described_class.new(main_session: session, extra_stuff: "ignored")
      result = tool.execute({"name" => "gh-issue"})

      expect(result).to include("Deactivated skill: gh-issue")
    end
  end
end
