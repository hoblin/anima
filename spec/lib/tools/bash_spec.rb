# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::Bash do
  let(:session) { create(:session) }
  let(:shell_session) { ShellSession.new(session_id: "bash-tool-#{SecureRandom.hex(4)}") }

  subject(:tool) { described_class.new(shell_session: shell_session, session: session) }

  after { shell_session.finalize }

  describe ".schema" do
    it "exposes the Anthropic tool contract: name, description, and input schema shape" do
      schema = described_class.schema

      expect(schema).to include(name: "bash", description: a_kind_of(String))
      expect(schema[:input_schema][:properties]).to include(
        command: include(type: "string"),
        commands: include(type: "array", items: {type: "string"})
      )
    end
  end

  describe ".prompt_snippet" do
    it "advertises bash to the agent in the system prompt menu" do
      expect(described_class.prompt_snippet).to eq("Run shell commands.")
    end
  end

  describe ".prompt_guidelines" do
    it "contributes nothing — guideline text is deferred to a follow-up ticket" do
      expect(described_class.prompt_guidelines).to eq([])
    end
  end

  describe "#execute" do
    context "with single command" do
      it "returns the rendered output" do
        result = tool.execute("command" => "echo hello")
        expect(result).to include("hello")
      end

      it "includes stderr in the merged stream" do
        result = tool.execute("command" => "echo oops >&2")
        expect(result).to include("oops")
      end

      it "preserves working directory between calls" do
        tool.execute("command" => "cd /tmp")
        result = tool.execute("command" => "pwd")
        expect(result).to include("/tmp")
      end

      it "preserves environment variables between calls" do
        tool.execute("command" => "export MY_PERSIST_VAR=kept")
        result = tool.execute("command" => "echo $MY_PERSIST_VAR")
        expect(result).to include("kept")
      end

      it "passes timeout parameter to the shell session" do
        expect(shell_session).to receive(:run).with("echo hi", timeout: 300, interrupt_check: an_instance_of(Proc)).and_return(output: "hi")
        tool.execute("command" => "echo hi", "timeout" => 300)
      end

      it "returns error for blank commands" do
        result = tool.execute("command" => "  ")
        expect(result).to be_a(Hash)
        expect(result[:error]).to include("blank")
      end

      it "delegates errors from the shell session" do
        shell_session.finalize
        result = tool.execute("command" => "echo hello")
        expect(result).to be_a(Hash)
        expect(result[:error]).to include("not running")
      end
    end

    context "with batch commands" do
      it "runs all commands and returns combined results with per-command headers" do
        result = tool.execute("commands" => ["echo first", "echo second", "echo third"])
        expect(result).to include("[1/3] $ echo first")
        expect(result).to include("[2/3] $ echo second")
        expect(result).to include("[3/3] $ echo third")
        expect(result).to include("first")
        expect(result).to include("second")
        expect(result).to include("third")
      end

      it "continues past shell session errors — agent reads merged output" do
        allow(shell_session).to receive(:run).with(anything, hash_including(:timeout, :interrupt_check)).and_return(
          {output: "ok"},
          {error: "Command timed out after 30s"},
          {output: "still running"}
        )
        result = tool.execute("commands" => ["echo ok", "sleep 999", "echo still running"])
        expect(result).to include("[1/3] $ echo ok")
        expect(result).to include("[2/3] $ sleep 999")
        expect(result).to include("Command timed out")
        expect(result).to include("[3/3] $ echo still running")
        expect(result).to include("still running")
      end

      it "preserves working directory across batch commands" do
        result = tool.execute("commands" => ["cd /tmp", "pwd"])
        expect(result).to include("/tmp")
      end
    end

    context "with batch edge cases" do
      it "returns error for empty commands array" do
        result = tool.execute("commands" => [])
        expect(result).to be_a(Hash)
        expect(result[:error]).to include("empty")
      end

      it "returns error for non-array commands" do
        result = tool.execute("commands" => "not an array")
        expect(result).to be_a(Hash)
        expect(result[:error]).to include("empty")
      end

      it "skips blank commands in batch" do
        result = tool.execute("commands" => ["echo ok", "  ", "echo done"])
        expect(result).to include("[1/3] $ echo ok")
        expect(result).to include("[2/3] $ (blank)\n(skipped — blank command)")
        expect(result).to include("[3/3] $ echo done")
      end

      it "passes timeout to each command in batch" do
        expect(shell_session).to receive(:run).with("echo a", timeout: 60, interrupt_check: an_instance_of(Proc)).and_return(output: "a")
        expect(shell_session).to receive(:run).with("echo b", timeout: 60, interrupt_check: an_instance_of(Proc)).and_return(output: "b")
        tool.execute("commands" => ["echo a", "echo b"], "timeout" => 60)
      end
    end

    context "when interrupted by user" do
      it "returns interrupted message for single command" do
        allow(shell_session).to receive(:run).and_return(
          {interrupted: true, output: ""}
        )

        result = tool.execute("command" => "sleep 30")
        expect(result).to include(LLM::Client::INTERRUPT_MESSAGE)
      end

      it "includes partial output in interrupted result" do
        allow(shell_session).to receive(:run).and_return(
          {interrupted: true, output: "partial output"}
        )
        result = tool.execute("command" => "long-command")
        expect(result).to include(LLM::Client::INTERRUPT_MESSAGE)
        expect(result).to include("Partial output:\npartial output")
      end

      it "skips remaining batch commands after interrupt" do
        allow(shell_session).to receive(:run).with("echo first", hash_including(:interrupt_check)).and_return(
          {output: "first"}
        )
        allow(shell_session).to receive(:run).with("sleep 999", hash_including(:interrupt_check)).and_return(
          {interrupted: true, output: ""}
        )
        expect(shell_session).not_to receive(:run).with("echo third", anything)

        result = tool.execute("commands" => ["echo first", "sleep 999", "echo third"])
        expect(result).to include("[1/3] $ echo first")
        expect(result).to include("[2/3] $ sleep 999")
        expect(result).to include(LLM::Client::INTERRUPT_MESSAGE)
        expect(result).to include("[3/3] $ echo third\n(skipped — interrupted by user)")
      end
    end

    context "with input validation" do
      it "returns error when both command and commands are provided" do
        result = tool.execute("command" => "echo hi", "commands" => ["echo hi"])
        expect(result).to be_a(Hash)
        expect(result[:error]).to include("not both")
      end

      it "returns error when neither command nor commands is provided" do
        result = tool.execute({})
        expect(result).to be_a(Hash)
        expect(result[:error]).to include("required")
      end
    end
  end
end
