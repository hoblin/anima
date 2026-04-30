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

    it "substitutes a placeholder when a command produces no output" do
      # `tmux wait-for -S` releases us before bash can redraw its prompt,
      # so commands with no output occasionally yield an all-whitespace
      # pane. Downstream Message#content validation would reject that.
      result = shell.run("true")
      expect(result[:output]).not_to be_empty
      expect(result[:output].strip).not_to be_empty
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

    it "injects pager-disabling env vars after the user's rcfiles run" do
      # The pager block matters most for tools like `gh`, `git`, `man` that
      # otherwise spawn `less` and stall the pane. Verifying the export
      # took effect — beating any `export PAGER=less` from ~/.zshrc.
      result = shell.run("echo PAGER=$PAGER GIT_PAGER=$GIT_PAGER LESS=$LESS")
      expect(result[:output]).to include("PAGER=cat")
      expect(result[:output]).to include("GIT_PAGER=cat")
      expect(result[:output]).to include("LESS=-eFRX")
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

    context "trailing blank lines" do
      # `tmux capture-pane -S -` returns the full scrollback padded out
      # to PANE_HEIGHT with empty rows. Without trimming, every byte of
      # that padding ends up in the LLM's context — and worse, can blow
      # the truncation budget for legitimately small output.
      it "collapses padding blank lines into a single trailing newline" do
        result = shell.run("echo hello")
        # exactly one trailing newline — the prompt line, then nothing
        expect(result[:output]).to match(/\n\z/)
        expect(result[:output]).not_to match(/\n{2,}\z/)
      end

      # Boundary: when *real* content fills the byte cap and tmux pads
      # blank rows after it, the trim must (a) strip the padding and
      # (b) leave the legitimate truncation notice intact. A regression
      # where the trim regex consumed the trailing notice would silently
      # drop the "[Truncated:]" suffix and mislead the LLM about why the
      # output ended.
      it "trims pane padding while preserving the truncation notice when real content exceeds the cap" do
        max = Anima::Settings.max_output_bytes
        # Real content larger than the cap, then trailing pane padding.
        # truncate() will cut the content + append the notice; the trim
        # runs *before* truncate, so it removes the padding first.
        big_content = "x" * (max + 1_000)
        synthetic_capture = "#{big_content}\n   \n   \n   \n"
        ok_status = instance_double(Process::Status, success?: true)
        allow(Open3).to receive(:capture2).and_call_original
        expect(Open3).to receive(:capture2)
          .with("tmux", "capture-pane", "-pJ", "-t", anything, "-S", "-", err: File::NULL)
          .and_return([synthetic_capture, ok_status])

        # Drive +capture_output+ directly — it's the unit under test and
        # going through +run+ would require a live command to complete
        # before the mock fires.
        output = shell.send(:capture_output)

        expect(output).to include("[Truncated: output exceeded #{max} bytes]")
        # Padding was trimmed before truncation, so the tail of the
        # output is the notice — not a run of blank rows after it.
        expect(output).not_to match(/\n\s*\n\z/)
      end

      # Counterpart: when the real content is small, trim+truncate must
      # leave it untouched. Pane padding alone should never push a small
      # command's output past the cap and trigger a false notice.
      it "does not trigger truncation for small commands surrounded by pane padding" do
        result = shell.run("echo small")
        expect(result[:output]).not_to include("[Truncated:")
      end

      # Edge: the regex requires a literal +\n+ to anchor its match. A
      # capture that ends in a non-blank line with no trailing newline
      # must therefore pass through unchanged — no synthesised newline,
      # no swallowed character. (In practice tmux always terminates with
      # +\n+, but this guards the regex contract.)
      it "leaves a capture without a trailing newline unchanged" do
        synthetic_capture = "no trailing newline"
        ok_status = instance_double(Process::Status, success?: true)
        allow(Open3).to receive(:capture2).and_call_original
        expect(Open3).to receive(:capture2)
          .with("tmux", "capture-pane", "-pJ", "-t", anything, "-S", "-", err: File::NULL)
          .and_return([synthetic_capture, ok_status])

        result = shell.run("printf no-newline")

        expect(result[:output]).to eq("no trailing newline")
      end

      # Mocked-Open3 path lets us inject a synthetic capture, isolating
      # the trim behaviour from any flakiness in tmux's actual padding.
      # tmux pads each empty pane row with literal spaces up to the pane
      # width, so the real shape is +"\n   ...   \n   ...   \n"+ — the
      # regex must collapse whitespace-only trailing lines, not just
      # consecutive newlines.
      it "trims trailing blank lines (including space-padded ones) from the captured pane" do
        synthetic_capture = "first line\nsecond line\n   \n   \n   \n"
        ok_status = instance_double(Process::Status, success?: true)
        allow(Open3).to receive(:capture2).and_call_original
        expect(Open3).to receive(:capture2)
          .with("tmux", "capture-pane", "-pJ", "-t", anything, "-S", "-", err: File::NULL)
          .and_return([synthetic_capture, ok_status])

        result = shell.run("echo whatever")

        expect(result[:output]).to eq("first line\nsecond line\n")
      end

      # Edge: an all-blank capture must still collapse to the
      # EMPTY_OUTPUT_PLACEHOLDER so PendingMessage validation accepts it
      # — the trim narrows the string but does not bypass the placeholder.
      it "still produces the empty-output placeholder when the capture is only blank lines" do
        synthetic_capture = "   \n   \n   \n"
        ok_status = instance_double(Process::Status, success?: true)
        allow(Open3).to receive(:capture2).and_call_original
        expect(Open3).to receive(:capture2)
          .with("tmux", "capture-pane", "-pJ", "-t", anything, "-S", "-", err: File::NULL)
          .and_return([synthetic_capture, ok_status])

        result = shell.run("true")

        expect(result[:output]).to eq(ShellSession::EMPTY_OUTPUT_PLACEHOLDER)
      end

      # Defensive: Open3 returns fresh strings in production, but the
      # trim path uses +force_encoding+ which mutates in place. A frozen
      # capture must not break the session — duplicate before mutating.
      # This file's +# frozen_string_literal: true+ pragma is what makes
      # the synthetic capture frozen; the +expect(...).to be_frozen+
      # below pins that contract so the test loses its teeth loudly
      # (rather than silently) if the pragma is ever removed.
      it "tolerates a frozen capture string without raising" do
        synthetic_capture = "frozen line\n   \n"
        expect(synthetic_capture).to be_frozen
        ok_status = instance_double(Process::Status, success?: true)
        allow(Open3).to receive(:capture2).and_call_original
        expect(Open3).to receive(:capture2)
          .with("tmux", "capture-pane", "-pJ", "-t", anything, "-S", "-", err: File::NULL)
          .and_return([synthetic_capture, ok_status])

        result = shell.run("echo frozen")

        expect(result[:output]).to eq("frozen line\n")
        expect(result).not_to have_key(:error)
      end
    end

    context "when capture-pane fails" do
      # Simulates the tmux session dying between `wait-for -S` firing and
      # the `capture-pane` call. Without an explicit error, the empty
      # capture would collapse to the EMPTY_OUTPUT_PLACEHOLDER and the LLM
      # would see "OK" — indistinguishable from a silent command success.
      it "returns an error so silent session death isn't reported as success" do
        failed_status = instance_double(Process::Status, success?: false)
        allow(Open3).to receive(:capture2).and_call_original
        expect(Open3).to receive(:capture2)
          .with("tmux", "capture-pane", "-pJ", "-t", anything, "-S", "-", err: File::NULL)
          .and_return(["", failed_status])

        result = shell.run("echo hello")

        expect(result[:error]).to include("capture-pane failed")
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
