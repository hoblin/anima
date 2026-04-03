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

    context "interrupt_check" do
      it "returns interrupted result when callback fires" do
        # Fires on the second poll, giving the command one cycle to start
        check_count = 0
        checker = -> { (check_count += 1) > 1 }

        allow(Anima::Settings).to receive(:interrupt_check_interval).and_return(0.5)
        result = shell.run("sleep 30", interrupt_check: checker)
        expect(result[:interrupted]).to be true
      end

      it "includes partial stdout captured before interrupt" do
        check_count = 0
        checker = -> { (check_count += 1) > 2 }

        allow(Anima::Settings).to receive(:interrupt_check_interval).and_return(0.3)
        result = shell.run("echo before_interrupt && sleep 30", interrupt_check: checker)
        expect(result[:interrupted]).to be true
        expect(result[:stdout]).to include("before_interrupt")
      end

      it "recovers the shell after interrupt" do
        checker = -> { true }

        allow(Anima::Settings).to receive(:interrupt_check_interval).and_return(0.5)
        shell.run("sleep 30", interrupt_check: checker)

        result = shell.run("echo recovered")
        expect(result[:stdout]).to eq("recovered")
      end

      it "preserves working directory after interrupt" do
        shell.run("cd /tmp")
        expect(shell.pwd).to eq("/tmp")

        checker = -> { true }
        allow(Anima::Settings).to receive(:interrupt_check_interval).and_return(0.5)
        shell.run("sleep 30", interrupt_check: checker)

        expect(shell.pwd).to eq("/tmp")
      end

      it "does not check interrupt when no callback provided" do
        result = shell.run("echo fast")
        expect(result[:stdout]).to eq("fast")
        expect(result[:interrupted]).to be_nil
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

    context "encoding" do
      it "returns UTF-8 encoded stdout even when PTY emits binary" do
        result = shell.run("printf '\\xc0\\xff valid ascii'")
        expect(result[:stdout].encoding).to eq(Encoding::UTF_8)
        expect(result[:stdout]).to be_valid_encoding
      end

      it "returns UTF-8 encoded stdout for normal output" do
        result = shell.run("echo hello")
        expect(result[:stdout].encoding).to eq(Encoding::UTF_8)
        expect(result[:stdout]).to be_valid_encoding
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

  describe "environment tracking" do
    describe "seed_env_snapshot" do
      it "sets @env_snapshot to real startup state on initialization" do
        # seed_env_snapshot runs inside start(), called by initialize
        snapshot = shell.send(:instance_variable_get, :@env_snapshot)
        expect(snapshot).to be_a(EnvironmentSnapshot)
        expect(snapshot.pwd).to eq(shell.pwd)
        expect(snapshot.pwd).not_to be_nil
      end

      it "is idempotent — calling twice preserves the same state" do
        snap_before = shell.send(:instance_variable_get, :@env_snapshot)
        shell.send(:seed_env_snapshot)
        snap_after = shell.send(:instance_variable_get, :@env_snapshot)
        expect(snap_after.pwd).to eq(snap_before.pwd)
        expect(snap_after.branch).to eq(snap_before.branch)
        expect(snap_after.repo).to eq(snap_before.repo)
      end

      it "captures nil branch and repo outside a git repo" do
        Dir.mktmpdir do |tmpdir|
          non_git_shell = described_class.new(session_id: "non-git-test")
          non_git_shell.run("cd #{Shellwords.shellescape(tmpdir)}")
          # Re-seed after cd to capture non-git state
          non_git_shell.send(:seed_env_snapshot)
          snapshot = non_git_shell.send(:instance_variable_get, :@env_snapshot)
          expect(snapshot.branch).to be_nil
          expect(snapshot.repo).to be_nil
        ensure
          non_git_shell&.finalize
        end
      end
    end

    describe "env_summary in tool responses" do
      it "returns nil when first command does not change environment" do
        # pwd matches the seeded snapshot — no footer expected
        result = shell.run("echo hello")
        expect(result[:env_summary]).to be_nil
      end

      it "reports location when directory changes" do
        result = shell.run("cd /tmp")
        expect(result[:env_summary]).to include("You are now in /tmp")
      end

      it "returns nil on subsequent command when environment is unchanged" do
        shell.run("cd /tmp") # changes env — footer emitted (discarded here)
        result = shell.run("echo hello")
        expect(result[:env_summary]).to be_nil
      end

      it "reports branch change without directory change" do
        Dir.mktmpdir do |tmpdir|
          shell.run("cd #{Shellwords.shellescape(tmpdir)}")
          shell.run("git init && git config user.name Test && git config user.email test@test.com && git commit --allow-empty -m init")
          branch = "test-branch-#{SecureRandom.hex(4)}"
          result = shell.run("git checkout -b #{branch}")
          expect(result[:env_summary]).to include("Branch changed to #{branch}.")
        end
      end

      it "reports project files on first visit to a directory" do
        Dir.mktmpdir do |tmpdir|
          File.write(File.join(tmpdir, "CLAUDE.md"), "# Test")
          result = shell.run("cd #{Shellwords.shellescape(tmpdir)}")
          expect(result[:env_summary]).to include("Project has instructions in CLAUDE.md")
        end
      end

      it "returns nil on error" do
        result = shell.run("exit 1")
        expect(result).to have_key(:error)
        expect(result).not_to have_key(:env_summary)
      end

      it "returns nil on interrupt" do
        checker = -> { true }
        allow(Anima::Settings).to receive(:interrupt_check_interval).and_return(0.5)
        result = shell.run("sleep 30", interrupt_check: checker)
        expect(result[:interrupted]).to be true
        expect(result).not_to have_key(:env_summary)
      end
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
