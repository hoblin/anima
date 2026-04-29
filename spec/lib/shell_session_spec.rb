# frozen_string_literal: true

require "rails_helper"

RSpec.describe ShellSession do
  subject(:shell) { described_class.new(session_id: "test-#{SecureRandom.hex(4)}") }

  after { shell.finalize }

  describe "#run" do
    it "returns the rendered command output" do
      result = shell.run("echo hello")
      expect(result[:output]).to include("hello")
      expect(result).not_to have_key(:error)
    end

    it "captures stderr in the merged terminal stream" do
      result = shell.run("echo error >&2")
      expect(result[:output]).to include("error")
    end

    it "captures both stdout and stderr together" do
      result = shell.run("echo out && echo err >&2")
      expect(result[:output]).to include("out")
      expect(result[:output]).to include("err")
    end

    it "surfaces error text from failing commands without surfacing exit codes" do
      result = shell.run("ls /nonexistent-path-#{SecureRandom.hex(4)}")
      expect(result[:output]).to match(/no such file|cannot access/i)
    end

    it "preserves working directory between calls" do
      shell.run("cd /tmp")
      result = shell.run("pwd")
      expect(result[:output]).to include("/tmp")
    end

    it "preserves environment variables between calls" do
      shell.run("export MY_SHELL_TEST_VAR=persistent")
      result = shell.run("echo $MY_SHELL_TEST_VAR")
      expect(result[:output]).to include("persistent")
    end

    it "handles multi-line output" do
      result = shell.run("printf 'line1\\nline2\\nline3\\n'")
      expect(result[:output]).to include("line1")
      expect(result[:output]).to include("line2")
      expect(result[:output]).to include("line3")
    end

    it "truncates output exceeding max_output_bytes" do
      result = shell.run("head -c #{Anima::Settings.max_output_bytes + 1000} /dev/zero | tr '\\0' 'x'")
      expect(result[:output]).to include("[Truncated:")
    end

    it "returns error when shell is finalized" do
      shell.finalize
      result = shell.run("echo hello")
      expect(result[:error]).to include("not running")
    end

    context "timeout" do
      it "returns error and partial output when the deadline expires" do
        result = shell.run("echo before_timeout && sleep 30", timeout: 1)
        expect(result[:error]).to include("timed out")
        expect(result[:error]).to include("before_timeout")
      end

      it "recovers cleanly so subsequent commands work" do
        shell.run("sleep 30", timeout: 1)
        result = shell.run("echo recovered")
        expect(result[:output]).to include("recovered")
      end
    end

    context "interrupt_check" do
      it "returns :interrupted when the callback fires" do
        check_count = 0
        checker = -> { (check_count += 1) > 1 }

        allow(Anima::Settings).to receive(:interrupt_check_interval).and_return(0.3)
        result = shell.run("sleep 30", interrupt_check: checker)
        expect(result[:interrupted]).to be true
      end

      it "includes partial output captured before the interrupt" do
        check_count = 0
        checker = -> { (check_count += 1) > 2 }

        allow(Anima::Settings).to receive(:interrupt_check_interval).and_return(0.3)
        result = shell.run("echo before_interrupt && sleep 30", interrupt_check: checker)
        expect(result[:interrupted]).to be true
        expect(result[:output]).to include("before_interrupt")
      end

      it "lets the shell continue after an interrupt" do
        checker = -> { true }

        allow(Anima::Settings).to receive(:interrupt_check_interval).and_return(0.3)
        shell.run("sleep 30", interrupt_check: checker)

        result = shell.run("echo recovered")
        expect(result[:output]).to include("recovered")
      end

      it "preserves working directory after interrupt" do
        shell.run("cd /tmp")
        expect(shell.pwd).to eq("/tmp")

        checker = -> { true }
        allow(Anima::Settings).to receive(:interrupt_check_interval).and_return(0.3)
        shell.run("sleep 30", interrupt_check: checker)

        expect(shell.pwd).to eq("/tmp")
      end

      it "does not flag :interrupted when no callback is provided" do
        result = shell.run("echo fast")
        expect(result[:output]).to include("fast")
        expect(result[:interrupted]).to be_nil
      end
    end

    context "encoding" do
      it "returns UTF-8 encoded output even when commands emit binary" do
        result = shell.run("printf '\\xc0\\xff valid ascii'")
        expect(result[:output].encoding).to eq(Encoding::UTF_8)
        expect(result[:output]).to be_valid_encoding
      end
    end
  end

  describe "#pwd" do
    it "tracks the current working directory via tmux" do
      shell.run("cd /tmp")
      expect(shell.pwd).to eq("/tmp")
    end

    it "updates after each cd" do
      shell.run("cd /tmp")
      expect(shell.pwd).to eq("/tmp")
      shell.run("cd /")
      expect(shell.pwd).to eq("/")
    end

    it "returns nil after finalize" do
      shell.finalize
      expect(shell.pwd).to be_nil
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
    it "kills the underlying tmux session" do
      session_id = shell.session_id
      shell.finalize
      expect(system("tmux", "has-session", "-t", "anima-shell-#{session_id}", out: File::NULL, err: File::NULL)).to be false
    end

    it "is idempotent" do
      shell.finalize
      expect { shell.finalize }.not_to raise_error
    end
  end

  describe ".for_session" do
    let(:session) { instance_double("Session", id: "test-session-#{SecureRandom.hex(4)}", initial_cwd: "/tmp", parent_session_id: nil) }

    after { described_class.release(session.id) }

    it "spawns a shell with initial_cwd for root sessions" do
      shell = described_class.for_session(session)
      expect(shell.pwd).to eq("/tmp")
    end

    it "isolates shells across different sessions" do
      other = instance_double("Session", id: "other-#{SecureRandom.hex(4)}", initial_cwd: "/tmp", parent_session_id: nil)

      a = described_class.for_session(session)
      b = described_class.for_session(other)

      a.run("cd /")
      expect(b.pwd).to eq("/tmp")
      expect(a.pwd).to eq("/")
    ensure
      described_class.release(other.id)
    end

    context "with a parent session" do
      let(:parent_id) { "parent-#{SecureRandom.hex(4)}" }
      let(:parent_session) { instance_double("Session", id: parent_id, initial_cwd: "/tmp", parent_session_id: nil) }
      let(:child_session) { instance_double("Session", id: "child-#{SecureRandom.hex(4)}", initial_cwd: "/", parent_session_id: parent_id) }

      after { described_class.release(parent_id) }

      it "inherits the parent's current cwd via tmux, ignoring child.initial_cwd" do
        parent_shell = described_class.for_session(parent_session)
        parent_shell.run("cd /var")

        child_shell = described_class.for_session(child_session)
        expect(child_shell.pwd).to eq("/var")
      ensure
        described_class.release(child_session.id)
      end

      it "falls back to child.initial_cwd when the parent tmux session is gone" do
        described_class.release(parent_id) # no parent shell exists

        child_shell = described_class.for_session(child_session)
        expect(child_shell.pwd).to eq("/")
      ensure
        described_class.release(child_session.id)
      end
    end
  end

  describe ".release" do
    let(:session_id) { "release-test-#{SecureRandom.hex(4)}" }

    it "kills the tmux session" do
      described_class.new(session_id: session_id)
      described_class.release(session_id)

      expect(system("tmux", "has-session", "-t", "anima-shell-#{session_id}", out: File::NULL, err: File::NULL)).to be false
    end

    it "is a no-op when no session exists" do
      expect { described_class.release("never-seen-#{SecureRandom.hex(4)}") }.not_to raise_error
    end

    it "is safe to call twice on the same session" do
      described_class.new(session_id: session_id)

      expect {
        described_class.release(session_id)
        described_class.release(session_id)
      }.not_to raise_error
    end
  end

  describe ".cwd_via_tmux" do
    let(:session_id) { "cwd-test-#{SecureRandom.hex(4)}" }

    after { described_class.release(session_id) }

    it "reads the pane's working directory directly from the tmux server" do
      shell = described_class.new(session_id: session_id, initial_cwd: "/tmp")
      expect(described_class.cwd_via_tmux(session_id)).to eq("/tmp")
      shell.run("cd /var")
      expect(described_class.cwd_via_tmux(session_id)).to eq("/var")
    end

    it "returns nil for a non-existent session" do
      expect(described_class.cwd_via_tmux("never-seen-#{SecureRandom.hex(4)}")).to be_nil
    end
  end
end
