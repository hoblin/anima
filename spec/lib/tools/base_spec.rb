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

  describe ".truncation_threshold" do
    it "returns the default tool response threshold from settings" do
      expect(described_class.truncation_threshold).to eq(Anima::Settings.max_tool_response_chars)
    end

    context "when overridden by a subclass" do
      let(:custom_tool) do
        Class.new(described_class) do
          def self.truncation_threshold = 5_000
        end
      end

      it "uses the subclass value" do
        expect(custom_tool.truncation_threshold).to eq(5_000)
      end
    end

    context "when set to nil to opt out" do
      it "returns nil for ReadTool" do
        expect(Tools::Read.truncation_threshold).to be_nil
      end
    end
  end

  describe "#execute" do
    it "raises NotImplementedError" do
      expect { described_class.new.execute({}) }.to raise_error(NotImplementedError)
    end
  end
end
