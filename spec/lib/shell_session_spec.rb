# frozen_string_literal: true

require "rails_helper"

RSpec.describe ShellSession do
  subject(:shell) { described_class.new(session_id: "test-#{SecureRandom.hex(4)}") }

  after { shell.finalize }

  describe "#run" do
    it "executes a command and returns stdout" do
      result = shell.run("echo hello")
      expect(result[:stdout]).to eq("hello")
      expect(result[:exit_code]).to eq(0)
    end

    it "returns empty stdout for commands with no output" do
      result = shell.run("true")
      expect(result[:stdout]).to eq("")
      expect(result[:exit_code]).to eq(0)
    end

    it "captures stderr separately" do
      result = shell.run("echo error >&2")
      expect(result[:stderr]).to include("error")
      expect(result[:stdout]).to eq("")
    end

    it "captures both stdout and stderr" do
      result = shell.run("echo out && echo err >&2")
      expect(result[:stdout]).to eq("out")
      expect(result[:stderr]).to include("err")
    end

    it "returns non-zero exit code for failing commands" do
      result = shell.run("(exit 42)")
      expect(result[:exit_code]).to eq(42)
    end

    it "reports error when exit kills the shell" do
      result = shell.run("exit 1")
      expect(result[:error]).to include("terminated unexpectedly")
    end

    it "preserves working directory between calls" do
      shell.run("cd /tmp")
      result = shell.run("pwd")
      expect(result[:stdout]).to eq("/tmp")
    end

    it "preserves environment variables between calls" do
      shell.run("export MY_SHELL_TEST_VAR=persistent")
      result = shell.run("echo $MY_SHELL_TEST_VAR")
      expect(result[:stdout]).to eq("persistent")
    end

    it "handles multi-line output" do
      result = shell.run("echo line1 && echo line2 && echo line3")
      expect(result[:stdout]).to eq("line1\nline2\nline3")
    end

    it "truncates stdout exceeding max_output_bytes" do
      result = shell.run("head -c #{Anima::Settings.max_output_bytes + 1000} /dev/zero | tr '\\0' 'x'")
      expect(result[:stdout]).to include("[Truncated:")
    end

    it "truncates stderr exceeding max_output_bytes" do
      result = shell.run("seq 1 100000 >&2")
      expect(result[:stderr]).to include("[Truncated:")
    end

    it "returns error when shell is finalized" do
      shell.finalize
      result = shell.run("echo hello")
      expect(result[:error]).to include("not running")
    end

    context "timeout" do
      it "returns error for long-running commands" do
        allow(Anima::Settings).to receive(:command_timeout).and_return(1)
        timed_shell = described_class.new(session_id: "timeout-#{SecureRandom.hex(4)}")
        result = timed_shell.run("sleep 30")
        expect(result[:error]).to include("timed out")
        timed_shell.finalize
      end

      it "includes partial output in timeout error" do
        allow(Anima::Settings).to receive(:command_timeout).and_return(2)
        timed_shell = described_class.new(session_id: "partial-#{SecureRandom.hex(4)}")
        result = timed_shell.run("echo 'before hang' && sleep 30")
        expect(result[:error]).to include("timed out")
        expect(result[:error]).to include("before hang")
        timed_shell.finalize
      end

      it "recovers after a command timeout" do
        allow(Anima::Settings).to receive(:command_timeout).and_return(1)
        timed_shell = described_class.new(session_id: "recover-#{SecureRandom.hex(4)}")
        timed_shell.run("sleep 30")

        allow(Anima::Settings).to receive(:command_timeout).and_call_original
        result = timed_shell.run("echo recovered")
        expect(result[:stdout]).to eq("recovered")
        timed_shell.finalize
      end
    end

    context "auto-respawn" do
      it "respawns after the shell process exits" do
        result = shell.run("exit 1")
        expect(result[:error]).to include("terminated unexpectedly")

        result = shell.run("echo respawned")
        expect(result[:stdout]).to eq("respawned")
      end

      it "preserves working directory after respawn" do
        shell.run("cd /tmp")
        expect(shell.pwd).to eq("/tmp")

        shell.run("exit 1")

        result = shell.run("pwd")
        expect(result[:stdout]).to eq("/tmp")
      end

      it "does not respawn after finalize" do
        shell.finalize
        result = shell.run("echo hello")
        expect(result[:error]).to include("not running")
      end
    end

    context "pager prevention" do
      it "disables pagers via PAGER and tool-specific env vars" do
        result = shell.run("echo $PAGER")
        expect(result[:stdout]).to eq("cat")

        result = shell.run("echo $GIT_PAGER")
        expect(result[:stdout]).to eq("cat")
      end

      it "configures less to auto-exit as safety net" do
        result = shell.run("echo $LESS")
        expect(result[:stdout]).to eq("-eFRX")
      end

      it "disables git credential prompts" do
        result = shell.run("echo $GIT_TERMINAL_PROMPT")
        expect(result[:stdout]).to eq("0")
      end
    end
  end

  describe "#pwd" do
    it "tracks the current working directory" do
      shell.run("cd /tmp")
      expect(shell.pwd).to eq("/tmp")
    end

    it "updates after each command" do
      shell.run("cd /tmp")
      expect(shell.pwd).to eq("/tmp")
      shell.run("cd /")
      expect(shell.pwd).to eq("/")
    end
  end

  describe "#alive?" do
    it "returns true for a running session" do
      expect(shell.alive?).to be true
    end

    it "returns false after finalize" do
      shell.finalize
      expect(shell.alive?).to be false
    end
  end

  describe "#finalize" do
    it "cleans up the FIFO file" do
      fifo_path = shell.instance_variable_get(:@fifo_path)
      expect(File.exist?(fifo_path)).to be true
      shell.finalize
      expect(File.exist?(fifo_path)).to be false
    end

    it "is idempotent" do
      shell.finalize
      expect { shell.finalize }.not_to raise_error
    end

    it "terminates the child process" do
      pid = shell.instance_variable_get(:@pid)
      shell.finalize
      expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
    end

    it "cleans up even when session is already dead" do
      pid = shell.instance_variable_get(:@pid)
      fifo_path = shell.instance_variable_get(:@fifo_path)

      # Simulate failed recovery that leaves @alive = false
      shell.run("exit 1")
      expect(shell.alive?).to be false

      shell.finalize
      expect(File.exist?(fifo_path)).to be false
      expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
    end
  end

  describe ".cleanup_orphans" do
    it "removes FIFO files for dead processes" do
      stale_path = File.join(Dir.tmpdir, "anima-stderr-99999999-deadbeef01234567")
      system("mkfifo", stale_path)
      expect(File.exist?(stale_path)).to be true

      described_class.cleanup_orphans

      expect(File.exist?(stale_path)).to be false
    end

    it "leaves FIFO files for live processes" do
      live_path = File.join(Dir.tmpdir, "anima-stderr-#{Process.pid}-deadbeef01234567")
      system("mkfifo", live_path)

      described_class.cleanup_orphans

      expect(File.exist?(live_path)).to be true
      begin
        File.delete(live_path)
      rescue SystemCallError
        # Best-effort cleanup
      end
    end
  end
end
