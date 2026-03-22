# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::Bash do
  let(:shell_session) { ShellSession.new(session_id: "bash-tool-#{SecureRandom.hex(4)}") }

  subject(:tool) { described_class.new(shell_session: shell_session) }

  after { shell_session.finalize }

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
    it "returns stdout and exit code" do
      result = tool.execute("command" => "echo hello")
      expect(result).to include("stdout:\nhello")
      expect(result).to include("exit_code: 0")
    end

    it "captures stderr" do
      result = tool.execute("command" => "echo oops >&2")
      expect(result).to include("stderr:")
      expect(result).to include("oops")
    end

    it "captures both stdout and stderr" do
      result = tool.execute("command" => "echo out && echo err >&2")
      expect(result).to include("stdout:\nout")
      expect(result).to include("err")
    end

    it "returns non-zero exit code" do
      result = tool.execute("command" => "(exit 42)")
      expect(result).to include("exit_code: 42")
    end

    it "returns only exit code for silent commands" do
      result = tool.execute("command" => "true")
      expect(result).to eq("exit_code: 0")
    end

    it "preserves working directory between calls" do
      tool.execute("command" => "cd /tmp")
      result = tool.execute("command" => "pwd")
      expect(result).to include("stdout:\n/tmp")
    end

    it "preserves environment variables between calls" do
      tool.execute("command" => "export MY_PERSIST_VAR=kept")
      result = tool.execute("command" => "echo $MY_PERSIST_VAR")
      expect(result).to include("stdout:\nkept")
    end

    it "passes timeout parameter to shell session" do
      expect(shell_session).to receive(:run).with("echo hi", timeout: 300).and_return(stdout: "hi\n", stderr: "", exit_code: 0)
      tool.execute("command" => "echo hi", "timeout" => 300)
    end

    it "returns error for blank commands" do
      result = tool.execute("command" => "  ")
      expect(result).to be_a(Hash)
      expect(result[:error]).to include("blank")
    end

    it "delegates errors from shell session" do
      shell_session.finalize
      result = tool.execute("command" => "echo hello")
      expect(result).to be_a(Hash)
      expect(result[:error]).to include("not running")
    end
  end
end
