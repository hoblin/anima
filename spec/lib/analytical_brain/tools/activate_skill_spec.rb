# frozen_string_literal: true

require "rails_helper"

RSpec.describe AnalyticalBrain::Tools::ActivateSkill do
  before { Skills::Registry.reload! }

  describe ".tool_name" do
    it { expect(described_class.tool_name).to eq("activate_skill") }
  end

  describe ".schema" do
    it "returns a valid Anthropic tool schema" do
      schema = described_class.schema

      expect(schema[:name]).to eq("activate_skill")
      expect(schema[:description]).to be_present
      expect(schema[:input_schema][:required]).to eq(%w[skill_name])
      expect(schema[:input_schema][:properties]).to have_key(:skill_name)
    end
  end

  describe "#execute" do
    let(:session) { Session.create! }
    let(:tool) { described_class.new(main_session: session) }

    it "activates a skill and returns confirmation" do
      result = tool.execute({"skill_name" => "gh-issue"})

      expect(result).to include("Activated skill: gh-issue")
      expect(result).to include("Issue writing with WHAT/WHY/HOW framework")
      expect(session.reload.active_skills).to include("gh-issue")
    end

    it "creates a skill PendingMessage on the session" do
      expect { tool.execute({"skill_name" => "gh-issue"}) }
        .to change { session.pending_messages.where(source_type: "skill").count }.by(1)
    end

    it "returns error for unknown skill" do
      result = tool.execute({"skill_name" => "nonexistent"})

      expect(result).to eq({error: "Unknown skill: nonexistent"})
      expect(session.reload.active_skills).to be_empty
    end

    it "returns error when name is blank" do
      result = tool.execute({"skill_name" => ""})

      expect(result).to eq({error: "Skill name cannot be blank"})
    end

    it "is idempotent — does not duplicate active skill" do
      tool.execute({"skill_name" => "gh-issue"})
      tool.execute({"skill_name" => "gh-issue"})

      expect(session.reload.active_skills.count("gh-issue")).to eq(1)
    end

    it "accepts context kwargs without error" do
      tool = described_class.new(main_session: session, extra_stuff: "ignored")
      result = tool.execute({"skill_name" => "gh-issue"})

      expect(result).to include("Activated skill: gh-issue")
    end
  end
end
