# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::Bash do
  let(:session) { Session.create! }
  let(:shell_session) { ShellSession.new(session_id: "bash-tool-#{SecureRandom.hex(4)}") }

  subject(:tool) { described_class.new(shell_session: shell_session, session: session) }

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
    it "defines command as a string property" do
      schema = described_class.input_schema
      expect(schema[:type]).to eq("object")
      expect(schema[:properties][:command][:type]).to eq("string")
    end

    it "defines commands as an array of strings property" do
      schema = described_class.input_schema
      commands_schema = schema[:properties][:commands]
      expect(commands_schema[:type]).to eq("array")
      expect(commands_schema[:items][:type]).to eq("string")
    end

    it "defines mode as an enum property" do
      schema = described_class.input_schema
      mode_schema = schema[:properties][:mode]
      expect(mode_schema[:type]).to eq("string")
      expect(mode_schema[:enum]).to contain_exactly("sequential", "parallel")
    end

    it "does not require any specific property" do
      schema = described_class.input_schema
      expect(schema[:required]).to be_nil
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
    context "with single command" do
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

      it "returns only exit code for silent commands (after env warmup)" do
        tool.execute("command" => "true")
        result = tool.execute("command" => "true")
        expect(result).to eq("exit_code: 0")
      end

      it "preserves working directory between calls" do
        tool.execute("command" => "cd /tmp")
        result = tool.execute("command" => "pwd")
        expect(result).to include("stdout:\n/tmp")
      end

      it "appends environment summary when directory changes" do
        result = tool.execute("command" => "cd /tmp")
        expect(result).to include("You are now in /tmp")
      end

      it "omits environment summary when nothing changes" do
        tool.execute("command" => "cd /tmp")
        result = tool.execute("command" => "echo hello")
        expect(result).not_to include("You are now in")
      end

      it "preserves environment variables between calls" do
        tool.execute("command" => "export MY_PERSIST_VAR=kept")
        result = tool.execute("command" => "echo $MY_PERSIST_VAR")
        expect(result).to include("stdout:\nkept")
      end

      it "passes timeout parameter to shell session" do
        expect(shell_session).to receive(:run).with("echo hi", timeout: 300, interrupt_check: an_instance_of(Proc)).and_return(stdout: "hi\n", stderr: "", exit_code: 0)
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

    context "with batch commands in sequential mode" do
      it "runs all commands and returns combined results" do
        result = tool.execute("commands" => ["echo first", "echo second", "echo third"])
        expect(result).to include("[1/3] $ echo first")
        expect(result).to include("[2/3] $ echo second")
        expect(result).to include("[3/3] $ echo third")
        expect(result).to include("stdout:\nfirst")
        expect(result).to include("stdout:\nsecond")
        expect(result).to include("stdout:\nthird")
      end

      it "defaults to sequential mode" do
        result = tool.execute("commands" => ["(exit 1)", "echo should-not-run"])
        expect(result).to include("[1/2] $ (exit 1)")
        expect(result).to include("exit_code: 1")
        expect(result).to include("[2/2] $ echo should-not-run\n(skipped)")
        expect(result).not_to include("should-not-run\nexit_code")
      end

      it "stops on first non-zero exit code" do
        result = tool.execute("commands" => ["echo ok", "(exit 2)", "echo never"], "mode" => "sequential")
        expect(result).to include("[1/3] $ echo ok")
        expect(result).to include("stdout:\nok")
        expect(result).to include("[2/3] $ (exit 2)")
        expect(result).to include("exit_code: 2")
        expect(result).to include("[3/3] $ echo never\n(skipped)")
      end

      it "stops on shell session errors" do
        allow(shell_session).to receive(:run).with(anything, hash_including(:timeout, :interrupt_check)).and_return(
          {stdout: "ok\n", stderr: "", exit_code: 0},
          {error: "Command timed out after 30s"},
          {stdout: "unreachable\n", stderr: "", exit_code: 0}
        )
        result = tool.execute("commands" => ["echo ok", "sleep 999", "echo unreachable"])
        expect(result).to include("[1/3] $ echo ok")
        expect(result).to include("[2/3] $ sleep 999")
        expect(result).to include("Command timed out")
        expect(result).to include("[3/3] $ echo unreachable\n(skipped)")
      end

      it "preserves working directory across batch commands" do
        result = tool.execute("commands" => ["cd /tmp", "pwd"])
        expect(result).to include("stdout:\n/tmp")
      end
    end

    context "with batch commands in parallel mode" do
      it "runs all commands regardless of failures" do
        result = tool.execute("commands" => ["echo first", "(exit 1)", "echo third"], "mode" => "parallel")
        expect(result).to include("[1/3] $ echo first")
        expect(result).to include("stdout:\nfirst")
        expect(result).to include("[2/3] $ (exit 1)")
        expect(result).to include("exit_code: 1")
        expect(result).to include("[3/3] $ echo third")
        expect(result).to include("stdout:\nthird")
      end

      it "continues past shell session errors" do
        allow(shell_session).to receive(:run).with(anything, hash_including(:timeout, :interrupt_check)).and_return(
          {error: "Command timed out after 30s"},
          {stdout: "still running\n", stderr: "", exit_code: 0}
        )
        result = tool.execute("commands" => ["sleep 999", "echo still running"], "mode" => "parallel")
        expect(result).to include("[1/2] $ sleep 999")
        expect(result).to include("Command timed out")
        expect(result).to include("[2/2] $ echo still running")
        expect(result).to include("stdout:\nstill running")
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
        expect(shell_session).to receive(:run).with("echo a", timeout: 60, interrupt_check: an_instance_of(Proc)).and_return(stdout: "a\n", stderr: "", exit_code: 0)
        expect(shell_session).to receive(:run).with("echo b", timeout: 60, interrupt_check: an_instance_of(Proc)).and_return(stdout: "b\n", stderr: "", exit_code: 0)
        tool.execute("commands" => ["echo a", "echo b"], "timeout" => 60)
      end
    end

    context "when interrupted by user" do
      it "returns interrupted message for single command" do
        session.update_column(:interrupt_requested, true)
        result = tool.execute("command" => "sleep 30")
        expect(result).to include("Your human wants your attention")
      end

      it "includes partial stdout in interrupted result" do
        allow(shell_session).to receive(:run).and_return(
          {interrupted: true, stdout: "partial output", stderr: ""}
        )
        result = tool.execute("command" => "long-command")
        expect(result).to include("Your human wants your attention")
        expect(result).to include("Partial stdout:\npartial output")
      end

      it "skips remaining batch commands after interrupt" do
        allow(shell_session).to receive(:run).with("echo first", hash_including(:interrupt_check)).and_return(
          {stdout: "first\n", stderr: "", exit_code: 0}
        )
        allow(shell_session).to receive(:run).with("sleep 999", hash_including(:interrupt_check)).and_return(
          {interrupted: true, stdout: "", stderr: ""}
        )
        expect(shell_session).not_to receive(:run).with("echo third", anything)

        result = tool.execute("commands" => ["echo first", "sleep 999", "echo third"])
        expect(result).to include("[1/3] $ echo first")
        expect(result).to include("[2/3] $ sleep 999")
        expect(result).to include(LLM::Client::INTERRUPT_MESSAGE)
        expect(result).to include("[3/3] $ echo third\n(skipped — interrupted by user)")
      end

      it "includes stderr in interrupted result" do
        allow(shell_session).to receive(:run).and_return(
          {interrupted: true, stdout: "", stderr: "warning: something"}
        )
        result = tool.execute("command" => "failing-command")
        expect(result).to include(LLM::Client::INTERRUPT_MESSAGE)
        expect(result).to include("stderr:\nwarning: something")
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
