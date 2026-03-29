# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::Think do
  subject(:tool) { described_class.new }

  describe ".tool_name" do
    it "returns think" do
      expect(described_class.tool_name).to eq("think")
    end
  end

  describe ".description" do
    it "returns a non-empty description" do
      expect(described_class.description).to be_a(String)
      expect(described_class.description).not_to be_empty
    end

    it "describes the tool" do
      expect(described_class.description).to include("Think")
    end
  end

  describe ".input_schema" do
    it "defines thoughts as a required string property" do
      schema = described_class.input_schema
      expect(schema[:type]).to eq("object")
      expect(schema[:properties][:thoughts][:type]).to eq("string")
      expect(schema[:required]).to include("thoughts")
    end

    it "defines visibility as an optional enum" do
      schema = described_class.input_schema
      visibility = schema[:properties][:visibility]
      expect(visibility[:type]).to eq("string")
      expect(visibility[:enum]).to eq(["inner", "aloud"])
    end
  end

  describe ".schema" do
    it "builds valid Anthropic tool schema" do
      schema = described_class.schema
      expect(schema).to include(name: "think", description: a_kind_of(String))
      expect(schema[:input_schema]).to be_a(Hash)
    end
  end

  describe "#execute" do
    it "returns OK for valid thoughts" do
      result = tool.execute("thoughts" => "I should check the config first.")
      expect(result).to eq("OK")
    end

    it "returns OK regardless of visibility mode" do
      result = tool.execute("thoughts" => "Checking config", "visibility" => "aloud")
      expect(result).to eq("OK")
    end

    it "returns OK for inner visibility" do
      result = tool.execute("thoughts" => "Planning next step", "visibility" => "inner")
      expect(result).to eq("OK")
    end

    it "returns error for blank thoughts" do
      result = tool.execute("thoughts" => "  ")
      expect(result).to be_a(Hash)
      expect(result[:error]).to include("blank")
    end

    it "returns error for empty thoughts" do
      result = tool.execute("thoughts" => "")
      expect(result).to be_a(Hash)
      expect(result[:error]).to include("blank")
    end

    it "accepts context kwargs without error" do
      tool_with_context = described_class.new(shell_session: double, session: double)
      result = tool_with_context.execute("thoughts" => "works with context")
      expect(result).to eq("OK")
    end
  end

  describe "#dynamic_schema" do
    before { allow(Anima::Settings).to receive(:thinking_budget).and_return(10_000) }

    context "for main sessions" do
      let(:session) { Session.create! }
      let(:tool_with_session) { described_class.new(session: session) }

      it "includes maxLength set to the full thinking budget" do
        schema = tool_with_session.dynamic_schema
        expect(schema[:input_schema][:properties][:thoughts][:maxLength]).to eq(10_000)
      end
    end

    context "for sub-agent sessions" do
      let(:parent) { Session.create! }
      let(:child) { Session.create!(parent_session: parent, prompt: "sub-agent") }
      let(:tool_with_child) { described_class.new(session: child) }

      it "includes maxLength set to half the thinking budget" do
        schema = tool_with_child.dynamic_schema
        expect(schema[:input_schema][:properties][:thoughts][:maxLength]).to eq(5_000)
      end
    end

    context "without session" do
      it "uses the full budget" do
        schema = tool.dynamic_schema
        expect(schema[:input_schema][:properties][:thoughts][:maxLength]).to eq(10_000)
      end
    end

    it "does not mutate the class-level schema" do
      tool.dynamic_schema
      expect(described_class.input_schema[:properties][:thoughts]).not_to have_key(:maxLength)
    end

    it "includes all standard schema fields" do
      schema = tool.dynamic_schema
      expect(schema[:name]).to eq("think")
      expect(schema[:description]).to be_present
      expect(schema[:input_schema][:properties][:visibility]).to be_present
    end
  end
end
