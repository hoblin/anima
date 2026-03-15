# frozen_string_literal: true

require "rails_helper"

RSpec.describe AnalyticalBrain::Tools::EverythingIsReady do
  describe ".tool_name" do
    it { expect(described_class.tool_name).to eq("everything_is_ready") }
  end

  describe ".schema" do
    it "returns a valid Anthropic tool schema with no required properties" do
      schema = described_class.schema

      expect(schema[:name]).to eq("everything_is_ready")
      expect(schema[:description]).to be_present
      expect(schema[:input_schema][:required]).to eq([])
      expect(schema[:input_schema][:properties]).to eq({})
    end
  end

  describe "#execute" do
    let(:tool) { described_class.new }

    it "returns an acknowledgment string" do
      result = tool.execute({})

      expect(result).to be_a(String)
      expect(result).to include("No changes needed")
    end

    it "does not raise with arbitrary input" do
      expect { tool.execute({"unexpected" => "value"}) }.not_to raise_error
    end

    it "accepts context kwargs without error" do
      tool = described_class.new(main_session: double, extra: "ignored")
      expect(tool.execute({})).to be_a(String)
    end
  end
end
