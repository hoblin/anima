# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::Base do
  describe ".tool_name" do
    it "raises NotImplementedError" do
      expect { described_class.tool_name }.to raise_error(NotImplementedError)
    end
  end

  describe ".description" do
    it "raises NotImplementedError" do
      expect { described_class.description }.to raise_error(NotImplementedError)
    end
  end

  describe ".input_schema" do
    it "raises NotImplementedError" do
      expect { described_class.input_schema }.to raise_error(NotImplementedError)
    end
  end

  describe ".schema" do
    let(:tool_class) do
      Class.new(described_class) do
        def self.tool_name = "test_tool"
        def self.description = "A test tool"
        def self.input_schema = {type: "object", properties: {}, required: []}
      end
    end

    it "returns the Anthropic tool schema hash" do
      expect(tool_class.schema).to eq(
        name: "test_tool",
        description: "A test tool",
        input_schema: {type: "object", properties: {}, required: []}
      )
    end
  end

  describe "#execute" do
    it "raises NotImplementedError" do
      expect { described_class.new.execute({}) }.to raise_error(NotImplementedError)
    end
  end
end
