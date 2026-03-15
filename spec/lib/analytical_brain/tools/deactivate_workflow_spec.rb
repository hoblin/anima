# frozen_string_literal: true

require "rails_helper"

RSpec.describe AnalyticalBrain::Tools::DeactivateWorkflow do
  before { Workflows::Registry.reload! }

  describe ".tool_name" do
    it { expect(described_class.tool_name).to eq("deactivate_workflow") }
  end

  describe ".schema" do
    it "returns a valid Anthropic tool schema" do
      schema = described_class.schema

      expect(schema[:name]).to eq("deactivate_workflow")
      expect(schema[:description]).to be_present
    end
  end

  describe "#execute" do
    let(:session) { Session.create! }
    let(:tool) { described_class.new(main_session: session) }

    it "deactivates the active workflow" do
      session.activate_workflow("feature")
      result = tool.execute({})

      expect(result).to eq("Deactivated workflow: feature")
      expect(session.reload.active_workflow).to be_nil
    end

    it "returns message when no workflow is active" do
      result = tool.execute({})

      expect(result).to eq("No workflow was active")
    end

    it "accepts context kwargs without error" do
      tool = described_class.new(main_session: session, extra_stuff: "ignored")
      session.activate_workflow("feature")

      result = tool.execute({})
      expect(result).to include("Deactivated workflow: feature")
    end
  end
end
