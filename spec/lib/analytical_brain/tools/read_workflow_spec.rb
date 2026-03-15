# frozen_string_literal: true

require "rails_helper"

RSpec.describe AnalyticalBrain::Tools::ReadWorkflow do
  before { Workflows::Registry.reload! }

  describe ".tool_name" do
    it { expect(described_class.tool_name).to eq("read_workflow") }
  end

  describe ".schema" do
    it "returns a valid Anthropic tool schema" do
      schema = described_class.schema

      expect(schema[:name]).to eq("read_workflow")
      expect(schema[:description]).to be_present
      expect(schema[:input_schema][:required]).to eq(%w[name])
      expect(schema[:input_schema][:properties]).to have_key(:name)
    end
  end

  describe "#execute" do
    let(:session) { Session.create! }
    let(:tool) { described_class.new(main_session: session) }

    it "activates a workflow and returns its full content" do
      result = tool.execute({"name" => "feature"})

      expect(result).to include("Workflow: feature")
      expect(result).to include("end-to-end")
      expect(session.reload.active_workflow).to eq("feature")
    end

    it "returns error for unknown workflow" do
      result = tool.execute({"name" => "nonexistent"})

      expect(result).to eq({error: "Unknown workflow: nonexistent"})
      expect(session.reload.active_workflow).to be_nil
    end

    it "returns error when name is blank" do
      result = tool.execute({"name" => ""})

      expect(result).to eq({error: "Workflow name cannot be blank"})
    end

    it "replaces previous active workflow" do
      tool.execute({"name" => "feature"})
      tool.execute({"name" => "commit"})

      expect(session.reload.active_workflow).to eq("commit")
    end

    it "accepts context kwargs without error" do
      tool = described_class.new(main_session: session, extra_stuff: "ignored")
      result = tool.execute({"name" => "feature"})

      expect(result).to include("Workflow: feature")
    end
  end
end
