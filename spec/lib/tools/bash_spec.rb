# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::Bash do
  subject(:tool) { described_class.new }

  describe ".tool_name" do
    it "returns bash" do
      expect(described_class.tool_name).to eq("bash")
    end
  end

  describe ".description" do
    it "returns a non-empty description" do
      expect(described_class.description).to be_a(String)
      expect(described_class.description).not_to be_empty
    end
  end

  describe ".input_schema" do
    it "defines command as a required string property" do
      schema = described_class.input_schema
      expect(schema[:type]).to eq("object")
      expect(schema[:properties][:command][:type]).to eq("string")
      expect(schema[:required]).to include("command")
    end
  end

  describe ".schema" do
    it "builds valid Anthropic tool schema" do
      schema = described_class.schema
      expect(schema).to include(name: "bash", description: a_kind_of(String))
      expect(schema[:input_schema]).to be_a(Hash)
    end
  end

  describe "#execute" do
    context "with a simple command" do
      it "returns stdout and exit code" do
        result = tool.execute("command" => "echo hello")
        expect(result).to include("stdout:\nhello")
        expect(result).to include("exit_code: 0")
      end
    end

    context "with a command that produces stderr" do
      it "includes stderr in the result" do
        result = tool.execute("command" => "echo error >&2")
        expect(result).to include("stderr:\nerror")
        expect(result).to include("exit_code: 0")
      end
    end

    context "with a command that produces both stdout and stderr" do
      it "includes both streams" do
        result = tool.execute("command" => "echo out && echo err >&2")
        expect(result).to include("stdout:\nout")
        expect(result).to include("stderr:\nerr")
        expect(result).to include("exit_code: 0")
      end
    end

    context "with a failing command" do
      it "returns non-zero exit code" do
        result = tool.execute("command" => "exit 42")
        expect(result).to include("exit_code: 42")
      end
    end

    context "with a command that produces no output" do
      it "returns only exit code" do
        result = tool.execute("command" => "true")
        expect(result).to eq("exit_code: 0")
      end
    end

    context "with a blank command" do
      it "returns an error" do
        result = tool.execute("command" => "  ")
        expect(result).to be_a(Hash)
        expect(result[:error]).to include("blank")
      end
    end

    context "with large output" do
      it "truncates stdout exceeding MAX_OUTPUT_BYTES" do
        result = tool.execute("command" => "head -c #{Tools::Bash::MAX_OUTPUT_BYTES + 1000} /dev/zero | tr '\\0' 'x'")
        expect(result).to include("[Truncated:")
      end
    end

    context "when the command times out" do
      it "returns a timeout error" do
        stub_const("Tools::Bash::COMMAND_TIMEOUT", 0.1)
        result = tool.execute("command" => "sleep 10")
        expect(result).to be_a(Hash)
        expect(result[:error]).to include("timed out")
      end
    end

    context "with stateless execution" do
      it "does not preserve state between calls" do
        tool.execute("command" => "export MY_TEST_VAR=hello")
        result = tool.execute("command" => "echo ${MY_TEST_VAR:-unset}")
        expect(result).to include("stdout:\nunset")
      end
    end
  end
end
