# frozen_string_literal: true

require "open3"
require "securerandom"
require "shellwords"

# Persistent shell session backed by a tmux session. Commands share
# working directory, environment, and shell history within a conversation.
# Multiple tools share the same session via {.for_session}.
#
# tmux is the source of truth — the {ShellSession} object is a disposable
# handle. The tmux session survives Anima crashes; teardown happens only
# through {.release} or {#finalize} (e.g. when the owning {Session} record
# is deleted).
#
# Sub-agents inherit cwd from their parent's tmux session at the moment
# the child shell is created. The lookup is dynamic — the parent's
# *current* cwd is captured, not a snapshot from spawn time.
#
# tmux is a hard runtime dependency. {#initialize} raises a clear error if
# tmux is missing.
#
# @example
#   shell = ShellSession.for_session(session)
#   shell.run("cd /tmp")
#   shell.run("pwd")
#   # => {output: "/tmp"}
class ShellSession
  # Prefix for every tmux session Anima owns. The full session name is
  # +anima-shell-{session_id}+; this prefix is what cleanup sweeps
  # (current and future) match on to leave unrelated tmux sessions alone.
  TMUX_SESSION_PREFIX = "anima-shell-"

  # Pane geometry — 200×50 is wide enough for most tool output without
  # forcing wraps that would inflate captures, and tall enough that the
  # agent sees normal command runs without scrollback in the visible area.
  PANE_WIDTH = 200
  PANE_HEIGHT = 50

  # Scrollback cap. tmux retains the last N lines of output per pane,
  # discarding older ones automatically — this is what bounds memory and
  # closes the OOM bug from the old PTY+FIFO design. Each line costs
  # roughly 1–2KB inside tmux, so 5000 lines ≈ 5–10MB resident per pane.
  HISTORY_LIMIT = 5_000

  # Env vars that disable interactive pagers and credential prompts in
  # the shell. Without these, tools like +gh+, +git+, +man+, +journalctl+
  # spawn +less+ and block the pane waiting for keypresses — our
  # +wait-for -S+ never fires, the run hangs to timeout. Set once at
  # session creation via +new-session -e+ so they propagate to every
  # command.
  SHELL_ENV = {
    "PAGER" => "cat",
    "GIT_PAGER" => "cat",
    "MANPAGER" => "cat",
    "LESS" => "-eFRX",
    "SYSTEMD_PAGER" => "",
    "AWS_PAGER" => "",
    "PSQL_PAGER" => "cat",
    "BAT_PAGER" => "cat",
    "GIT_TERMINAL_PROMPT" => "0"
  }.freeze

  # tmux format-string for the pane's current working directory.
  # Single-quoted intentionally — tmux performs the +#{...}+ substitution
  # server-side, so Ruby must pass the literal string.
  PANE_CWD_FORMAT = '#{pane_current_path}' # rubocop:disable Lint/InterpolationCheck

  # @return [Integer, String] identifier of the {Session} this shell belongs to
  attr_reader :session_id

  # Returns the shell bound to +session+. Sub-agents inherit cwd from
  # their parent's tmux session via {.cwd_via_tmux}, falling back to
  # +session.initial_cwd+ for root sessions or when the parent's tmux
  # session is gone.
  #
  # @param session [Session] owning conversation
  # @return [ShellSession]
  def self.for_session(session)
    cwd = parent_cwd_for(session) || session.initial_cwd
    new(session_id: session.id, initial_cwd: cwd)
  end

  # Kills the tmux session for +session_id+. Idempotent — silently
  # succeeds when no such session exists.
  #
  # @param session_id [Integer, String]
  # @return [void]
  def self.release(session_id)
    target = "#{TMUX_SESSION_PREFIX}#{session_id}"
    system("tmux", "kill-session", "-t", target, out: File::NULL, err: File::NULL)
    nil
  end

  # Reads the working directory of +session_id+'s tmux pane directly
  # from the tmux server. Works even when the pane is mid-command — the
  # +pane_current_path+ format variable is a server-side property
  # (kernel +/proc/{pid}/cwd+ readlink), not shell-mediated.
  #
  # @param session_id [Integer, String]
  # @return [String, nil] absolute path, or nil when the session is gone
  def self.cwd_via_tmux(session_id)
    target = "#{TMUX_SESSION_PREFIX}#{session_id}"
    output, status = Open3.capture2(
      "tmux", "display-message", "-p", "-t", target, PANE_CWD_FORMAT,
      err: File::NULL
    )
    return nil unless status.success?
    cwd = output.strip
    cwd.empty? ? nil : cwd
  end

  # @return [String, nil] parent's current working directory, or nil for
  #   root sessions and when the parent's tmux session is gone
  def self.parent_cwd_for(session)
    return nil unless session.parent_session_id
    cwd_via_tmux(session.parent_session_id)
  end
  private_class_method :parent_cwd_for

  # @param session_id [Integer, String]
  # @param initial_cwd [String, nil] starting working directory
  # @raise [RuntimeError] if tmux is missing or the session can't be created
  def initialize(session_id:, initial_cwd: nil)
    @session_id = session_id
    @target = "#{TMUX_SESSION_PREFIX}#{session_id}"
    ensure_session(initial_cwd)
  end

  # Execute a command in the persistent shell.
  #
  # Capture sequence:
  # 1. +tmux clear-history+ wipes off-screen scrollback.
  # 2. +send-keys "clear; <cmd>; tmux wait-for -S done-<uuid>"+ — bash
  #    receives the line: shell +clear+ erases the visible pane (and
  #    scrollback via the +\e[3J+ sequence on modern terminfo), +<cmd>+
  #    runs, then +wait-for -S+ signals the synchronization channel.
  # 3. We block on +tmux wait-for done-<uuid>+ in a child process and
  #    poll for interrupt/timeout. On either we send +C-c+ to the pane
  #    and kill the wait-for child — interactive bash discards the
  #    rest of the input line on SIGINT, so the trailing +wait-for -S+
  #    never fires and we can't rely on natural signaling.
  # 4. +capture-pane -pJ -S -+ pulls scrollback + visible pane, which
  #    (after +clear+ wiped both) is exactly the new command's output
  #    and trailing prompt.
  #
  # @param command [String] bash command to execute
  # @param timeout [Integer, nil] per-call timeout in seconds; defaults to
  #   {Anima::Settings.command_timeout}
  # @param interrupt_check [Proc, nil] callable returning truthy when the
  #   user has requested an interrupt
  # @return [Hash{Symbol => Object}] +:output+ on success;
  #   +:output+ + +:interrupted+ on user cancel; +:error+ on failure
  def run(command, timeout: nil, interrupt_check: nil)
    return {error: "Shell session is not running"} unless alive?

    uuid = SecureRandom.hex(8)
    timeout ||= Anima::Settings.command_timeout

    system("tmux", "clear-history", "-t", @target, out: File::NULL, err: File::NULL)
    line = "clear; #{command}; tmux wait-for -S done-#{uuid}"
    system("tmux", "send-keys", "-t", @target, line, "Enter", out: File::NULL, err: File::NULL)

    state = wait_for_completion(uuid, timeout, interrupt_check)
    output = capture_output

    case state
    when :done then {output: output}
    when :interrupted then {output: output, interrupted: true}
    when :timeout then {error: "Command timed out after #{timeout} seconds.\n\n#{output}"}
    end
  rescue => error # rubocop:disable Lint/RescueException -- LLM must always get a result hash, never a stack trace
    {error: "#{error.class}: #{error.message}"}
  end

  # @return [Boolean] whether the underlying tmux session exists
  def alive?
    !!system("tmux", "has-session", "-t", @target, out: File::NULL, err: File::NULL)
  end

  # Kills the underlying tmux session. Idempotent.
  def finalize
    self.class.release(@session_id)
  end

  # Reads the shell's current working directory directly from the tmux
  # server. Works even mid-command — the lookup is server-side, not
  # shell-mediated.
  #
  # @return [String, nil]
  def pwd
    self.class.cwd_via_tmux(@session_id)
  end

  private

  def ensure_session(cwd)
    return if alive?

    unless system("tmux", "-V", out: File::NULL, err: File::NULL)
      raise "tmux is not installed. Install it with your package manager (e.g. `apt install tmux`)."
    end

    args = ["tmux", "new-session", "-d", "-s", @target, "-x", PANE_WIDTH.to_s, "-y", PANE_HEIGHT.to_s]
    args.push("-c", cwd) if cwd && File.directory?(cwd)
    system(*args, out: File::NULL, err: File::NULL)

    raise "tmux session #{@target} could not be created" unless alive?

    system(
      "tmux", "set-option", "-t", @target, "history-limit", HISTORY_LIMIT.to_s,
      out: File::NULL, err: File::NULL
    )

    inject_shell_env
  end

  # Sends +export+ statements to the pane after the user's login shell
  # has sourced its rcfiles, so our pager-disabling env beats any
  # +export PAGER=less+ in +~/.zshrc+ etc. Blocks via +wait-for+ so
  # subsequent {#run} calls see the new env.
  def inject_shell_env
    uuid = SecureRandom.hex(8)
    exports = SHELL_ENV.map { |k, v| "export #{k}=#{v.empty? ? "''" : v.shellescape}" }.join("; ")
    line = "#{exports}; tmux wait-for -S init-#{uuid}"
    system("tmux", "send-keys", "-t", @target, line, "Enter", out: File::NULL, err: File::NULL)
    pid = Process.spawn("tmux", "wait-for", "init-#{uuid}", out: File::NULL, err: File::NULL)
    waiter = Process.detach(pid)
    return if waiter.join(5)

    begin
      Process.kill("TERM", pid)
    rescue Errno::ESRCH
      # Already exited between waiter.join's deadline and our kill — fine.
    end
    waiter.join
    raise "tmux session #{@target} init timed out"
  end

  # Blocks until the +tmux wait-for+ child exits (= the bash command in
  # the pane finished and ran +tmux wait-for -S+), the deadline expires,
  # or the user requests an interrupt.
  #
  # No polling: {Process.detach} returns a Thread that waits on the
  # child, and {Thread#join} blocks until either the thread finishes or
  # the timeout fires — returning immediately when the child exits.
  #
  # On cancel we send +C-c+ to abort the running command, then kill the
  # wait-for child directly — interactive bash discards the rest of the
  # input line on SIGINT, so the trailing +tmux wait-for -S+ never fires
  # and we can't rely on natural signaling.
  #
  # @return [Symbol] +:done+, +:interrupted+, or +:timeout+
  def wait_for_completion(uuid, timeout, interrupt_check)
    pid = Process.spawn("tmux", "wait-for", "done-#{uuid}", out: File::NULL, err: File::NULL)
    waiter = Process.detach(pid)
    deadline = monotonic_now + timeout
    interrupt_interval = interrupt_check ? Anima::Settings.interrupt_check_interval : timeout

    loop do
      remaining = deadline - monotonic_now
      return cancel_command(pid, waiter, :timeout) if remaining <= 0

      # Block until child exits, the next interrupt-check tick, or the deadline.
      slice = [remaining, interrupt_interval].min
      return :done if waiter.join(slice)

      return cancel_command(pid, waiter, :interrupted) if interrupt_check&.call
    end
  end

  # Sends Ctrl+C to abort the running command, kills the wait-for
  # child, and waits for the detach thread to reap it. Returns +state+
  # so call sites can inline +return cancel_command(...)+.
  def cancel_command(pid, waiter, state)
    send_ctrl_c
    begin
      Process.kill("TERM", pid)
    rescue Errno::ESRCH
      # wait-for already exited (raced with our kill) — fine.
    end
    waiter.join
    state
  end

  def send_ctrl_c
    system("tmux", "send-keys", "-t", @target, "C-c", out: File::NULL, err: File::NULL)
  end

  # Captures the pane scrollback + visible content. Because we ran
  # +tmux clear-history+ before sending and the shell +clear+ wiped both
  # visible pane and scrollback (via the +\e[3J+ sequence on modern
  # terminfo), what we capture is exactly the new command's output and
  # trailing prompt — nothing leaked from the previous pane state.
  # The +-J+ flag joins terminal-wrapped lines so a long single-line
  # output comes back whole.
  def capture_output
    raw, _ = Open3.capture2("tmux", "capture-pane", "-pJ", "-t", @target, "-S", "-", err: File::NULL)
    truncate(raw.dup.force_encoding("UTF-8").scrub)
  end

  # Truncates +output+ to {Anima::Settings.max_output_bytes}. The
  # truncation notice itself counts against the cap, so the returned
  # string is always +<= max_output_bytes+ — a contract callers can rely
  # on for context-window budgeting.
  def truncate(output)
    max = Anima::Settings.max_output_bytes
    return output if output.bytesize <= max
    notice = "\n\n[Truncated: output exceeded #{max} bytes]"
    output.byteslice(0, max - notice.bytesize).scrub + notice
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
