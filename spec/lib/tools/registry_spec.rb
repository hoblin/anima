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
    before { allow(Anima::Settings).to receive(:tool_timeout).and_return(180) }

    it "returns empty array when no tools registered" do
      expect(registry.schemas).to eq([])
    end

    it "returns schema array for registered tools with injected timeout parameter" do
      registry.register(tool_class)
      schemas = registry.schemas

      expect(schemas.length).to eq(1)
      expect(schemas.first[:name]).to eq("echo")
      expect(schemas.first[:input_schema][:properties][:text]).to eq({type: "string"})
      expect(schemas.first[:input_schema][:properties]["timeout"]).to include(type: "integer")
    end

    it "does not mutate the original tool schema" do
      registry.register(tool_class)
      registry.schemas

      expect(tool_class.input_schema[:properties]).not_to have_key("timeout")
    end

    context "with budget-aware tools" do
      before { allow(Anima::Settings).to receive(:thinking_budget).and_return(8_000) }

      it "uses schema_with_budget for the Think tool" do
        session = Session.create!
        registry_with_ctx = described_class.new(context: {session: session})
        registry_with_ctx.register(Tools::Think)

        schemas = registry_with_ctx.schemas
        think_schema = schemas.find { |s| s[:name] == "think" }

        expect(think_schema[:input_schema][:properties][:thoughts][:maxLength]).to eq(8_000)
      end

      it "uses half budget for sub-agent sessions" do
        parent = Session.create!
        child = Session.create!(parent_session: parent, prompt: "sub-agent")
        registry_with_ctx = described_class.new(context: {session: child})
        registry_with_ctx.register(Tools::Think)

        schemas = registry_with_ctx.schemas
        think_schema = schemas.find { |s| s[:name] == "think" }

        expect(think_schema[:input_schema][:properties][:thoughts][:maxLength]).to eq(4_000)
      end
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

    context "with context" do
      let(:context_tool_class) do
        Class.new(Tools::Base) do
          def self.tool_name = "ctx"
          def self.description = "Context test"
          def self.input_schema = {type: "object", properties: {}, required: []}

          def initialize(test_value: nil, **)
            @test_value = test_value
          end

          def execute(_input)
            @test_value.to_s
          end
        end
      end

      it "passes context to tool constructor" do
        registry_with_ctx = described_class.new(context: {test_value: "injected"})
        registry_with_ctx.register(context_tool_class)

        result = registry_with_ctx.execute("ctx", {})
        expect(result).to eq("injected")
      end

      it "works without context for tools that don't need it" do
        registry.register(context_tool_class)
        result = registry.execute("ctx", {})
        expect(result).to eq("")
      end
    end
  end

  describe "instance-based tools" do
    before { allow(Anima::Settings).to receive(:tool_timeout).and_return(180) }

    let(:tool_instance) do
      instance_double(Tools::McpTool,
        tool_name: "server__tool",
        schema: {name: "server__tool", description: "Test", input_schema: {}})
    end

    it "registers and looks up instance-based tools" do
      registry.register(tool_instance)

      expect(registry.registered?("server__tool")).to be true
      expect(registry.schemas.first[:name]).to eq("server__tool")
    end

    it "executes instance-based tools directly without calling .new" do
      allow(tool_instance).to receive(:execute).with({"key" => "val"}).and_return("result")

      registry.register(tool_instance)
      result = registry.execute("server__tool", {"key" => "val"})

      expect(result).to eq("result")
      expect(tool_instance).not_to respond_to(:new)
    end
  end

  describe "#truncation_threshold" do
    it "returns the tool's truncation threshold" do
      registry.register(tool_class)
      expect(registry.truncation_threshold("echo")).to eq(Anima::Settings.max_tool_response_chars)
    end

    it "returns nil when the tool opts out" do
      registry.register(Tools::Read)
      expect(registry.truncation_threshold("read")).to be_nil
    end

    it "returns default threshold for unknown tools" do
      expect(registry.truncation_threshold("missing")).to eq(Anima::Settings.max_tool_response_chars)
    end

    it "returns default threshold for instance-based tools without truncation_threshold" do
      instance = instance_double(Tools::McpTool,
        tool_name: "server__tool",
        schema: {name: "server__tool", description: "Test", input_schema: {}})
      registry.register(instance)

      expect(registry.truncation_threshold("server__tool")).to eq(Anima::Settings.max_tool_response_chars)
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
