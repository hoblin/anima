# frozen_string_literal: true

require "rails_helper"

RSpec.describe Mneme::Tools::EverythingOk do
  describe ".tool_name" do
    it { expect(described_class.tool_name).to eq("everything_ok") }
  end

  describe ".schema" do
    it "returns a valid Anthropic tool schema with no required properties" do
      schema = described_class.schema

      expect(schema[:name]).to eq("everything_ok")
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
      expect(result).to include("No snapshot needed")
    end

    it "accepts context kwargs without error" do
      tool = described_class.new(main_session: double, from_message_id: 1, to_message_id: 10)
      expect(tool.execute({})).to be_a(String)
    end
  end
end
