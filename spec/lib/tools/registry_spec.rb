# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::Registry do
  subject(:registry) { described_class.new }

  let(:tool_class) do
    Class.new(Tools::Base) do
      def self.tool_name = "echo"
      def self.description = "Echoes input back"

      def self.input_schema
        {type: "object", properties: {text: {type: "string"}}, required: ["text"]}
      end

      def execute(input)
        input["text"]
      end
    end
  end

  describe "#register" do
    it "registers a tool class by name" do
      registry.register(tool_class)
      expect(registry.registered?("echo")).to be true
    end
  end

  describe "#schemas" do
    it "returns empty array when no tools registered" do
      expect(registry.schemas).to eq([])
    end

    it "returns schema array for registered tools" do
      registry.register(tool_class)

      expect(registry.schemas).to eq([
        {
          name: "echo",
          description: "Echoes input back",
          input_schema: {type: "object", properties: {text: {type: "string"}}, required: ["text"]}
        }
      ])
    end
  end

  describe "#execute" do
    before { registry.register(tool_class) }

    it "executes a registered tool and returns the result" do
      result = registry.execute("echo", {"text" => "hello"})
      expect(result).to eq("hello")
    end

    it "raises UnknownToolError for unregistered tools" do
      expect {
        registry.execute("unknown", {})
      }.to raise_error(Tools::UnknownToolError, "Unknown tool: unknown")
    end
  end

  describe "#registered?" do
    it "returns false for unregistered tools" do
      expect(registry.registered?("echo")).to be false
    end

    it "returns true for registered tools" do
      registry.register(tool_class)
      expect(registry.registered?("echo")).to be true
    end
  end

  describe "#any?" do
    it "returns false when empty" do
      expect(registry.any?).to be false
    end

    it "returns true when tools are registered" do
      registry.register(tool_class)
      expect(registry.any?).to be true
    end
  end
end
