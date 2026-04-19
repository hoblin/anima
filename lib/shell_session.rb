# frozen_string_literal: true

require "io/console"
require "open3"
require "pathname"
require "pty"
require "securerandom"
require "shellwords"
require "uri"

# Immutable snapshot of the shell's environment for change detection.
# Compared between commands to produce natural-language summaries of what
# changed — the agent discovers its environment through Bash tool responses.
#
# @!attribute [r] pwd
#   @return [String, nil] current working directory
# @!attribute [r] branch
#   @return [String, nil] current git branch name
# @!attribute [r] repo
#   @return [String, nil] "owner/repo" extracted from git origin remote
# @!attribute [r] project_files
#   @return [Array<String>] sorted relative paths to project instruction files
EnvironmentSnapshot = Data.define(:pwd, :branch, :repo, :project_files) do
  # Sentinel for "never detected" — diffs against this produce a full snapshot.
  def self.blank = new(pwd: nil, branch: nil, repo: nil, project_files: [])
end

# Persistent shell session backed by a PTY with FIFO-based stderr separation.
# Commands share working directory, environment variables, and shell history
# within a conversation. Multiple tools share the same session.
#
# Auto-recovers from timeouts and crashes: if the shell dies, the next command
# transparently respawns a fresh shell and restores the working directory.
#
# After each successful command, detects environment changes (CWD, git branch,
# project files) and includes a natural-language summary in the result hash.
# This replaces the old EnvironmentProbe system-prompt injection, keeping the
# system prompt static for prompt caching.
#
# Uses IO.select-based deadlines instead of Timeout.timeout for all PTY reads.
# Timeout.timeout is unsafe with PTY I/O — it uses Thread.raise which can
# corrupt mutex state, leave resources inconsistent, and cause exceptions
# to fire outside handler blocks when nested.
#
# @example
#   session = ShellSession.new(session_id: 42)
#   session.run("cd /tmp")
#   session.run("pwd")
#   # => {stdout: "/tmp", stderr: "", exit_code: 0}
#   session.finalize
class ShellSession
  # @return [String, nil] current working directory of the shell process
  attr_reader :pwd

  # Factory that binds a new ShellSession to a {Session}, preseeding the
  # working directory from +session.initial_cwd+ so tools run in the same
  # directory the session was born in. Jobs that need a registry-aware
  # shell (DrainJob, ToolExecutionJob) share this one call.
  #
  # @param session [Session] owning session
  # @return [ShellSession]
  def self.for_session(session)
    shell = new(session_id: session.id)
    cwd = session.initial_cwd
    shell.run("cd #{Shellwords.shellescape(cwd)}") if cwd.present? && File.directory?(cwd)
    shell
  end

  # @param session_id [Integer, String] unique identifier for logging/diagnostics
  def initialize(session_id:)
    @session_id = session_id
    @mutex = Mutex.new
    @fifo_path = File.join(Dir.tmpdir, "anima-stderr-#{Process.pid}-#{SecureRandom.hex(8)}")
    @alive = false
    @finalized = false
    @pwd = nil
    @env_snapshot = nil
    @read_buffer = +""
    self.class.cleanup_orphans
    start
    self.class.register(self)
  end

  # Execute a command in the persistent shell. Respawns the shell
  # automatically if the previous session died (timeout, crash, etc.).
  #
  # @param command [String] bash command to execute
  # @param timeout [Integer, nil] per-call timeout in seconds; overrides
  #   Settings.command_timeout when provided
  # @param interrupt_check [Proc, nil] callable returning truthy when the
  #   user has requested an interrupt. Polled every
  #   {Anima::Settings.interrupt_check_interval} seconds during command execution.
  # @return [Hash] with :stdout, :stderr, :exit_code keys on success
  # @return [Hash] with :interrupted, :stdout, :stderr keys on user interrupt
  # @return [Hash] with :error key on failure
  def run(command, timeout: nil, interrupt_check: nil)
    @mutex.synchronize do
      return {error: "Shell session is not running"} if @finalized
      restart unless @alive
      execute_in_pty(command, timeout: timeout, interrupt_check: interrupt_check)
    end
  rescue => error # rubocop:disable Lint/RescueException -- LLM must always get a result hash, never a stack trace
    {error: "#{error.class}: #{error.message}"}
  end

  # Clean up PTY, FIFO, and child process. Permanent — the session
  # will not auto-respawn after this call.
  def finalize
    @mutex.synchronize do
      @finalized = true
      teardown
    end
    self.class.unregister(self)
  end

  # @return [Boolean] whether the shell process is still running
  def alive?
    @mutex.synchronize { @alive }
  end

  # --- Class-level session tracking for at_exit cleanup ---

  @sessions = []
  @sessions_mutex = Mutex.new

  class << self
    # @api private
    def register(session)
      @sessions_mutex.synchronize { @sessions << session }
    end

    # @api private
    def unregister(session)
      @sessions_mutex.synchronize { @sessions.delete(session) }
    end

    # Finalize all live sessions. Called automatically via at_exit.
    def cleanup_all
      @sessions_mutex.synchronize do
        @sessions.each { |session| session.send(:teardown) }
        @sessions.clear
      end
    end

    # Resolves the shell to spawn. Falls back to /bin/bash when +$SHELL+ is
    # unset or empty (e.g. cron, systemd, minimal containers).
    #
    # @return [String] absolute path to the login shell
    def login_shell
      ENV["SHELL"].presence || "/bin/bash"
    end

    # Remove stale FIFO files left by crashed processes.
    # FIFO naming format: anima-stderr-{pid}-{hex}
    def cleanup_orphans
      Dir.glob(File.join(Dir.tmpdir, "anima-stderr-*")).each do |path|
        match = File.basename(path).match(/\Aanima-stderr-(\d+)-/)
        next unless match

        pid = match[1].to_i
        next if pid <= 0

        begin
          Process.kill(0, pid)
        rescue Errno::ESRCH
          begin
            File.delete(path)
          rescue SystemCallError
            # Best-effort cleanup
          end
        rescue Errno::EPERM
          # Process exists but we can't signal it — leave it
        end
      end
    end
  end

  at_exit { ShellSession.cleanup_all }

  private

  def start
    create_fifo
    spawn_shell
    start_stderr_reader
    init_shell
    update_pwd
    seed_env_snapshot
    @alive = true
  end

  # Shuts down the current shell and spawns a fresh one, restoring the
  # previous working directory. Called automatically when @alive is false.
  def restart
    saved_pwd = @pwd
    teardown
    @fifo_path = File.join(Dir.tmpdir, "anima-stderr-#{Process.pid}-#{SecureRandom.hex(8)}")
    start
    restore_working_directory(saved_pwd)
  end

  # Restores the shell's working directory after a respawn.
  # Skips silently if the directory no longer exists.
  #
  # @param saved_pwd [String, nil] directory path to restore
  # @return [void]
  def restore_working_directory(saved_pwd)
    return unless saved_pwd && File.directory?(saved_pwd)
    execute_in_pty("cd #{Shellwords.shellescape(saved_pwd)}")
  end

  def create_fifo
    File.mkfifo(@fifo_path, 0o600)
  rescue Errno::EEXIST
    # FIFO already exists — reuse it
  end

  # Env vars that prevent interactive pagers and credential prompts from
  # hanging the PTY. We need a PTY (not pipes) for pwd tracking via /proc
  # and signal handling, but this makes programs think they're on a terminal
  # and launch pagers. No single switch disables all pagers — each tool has
  # its own env var — so we set a comprehensive list plus LESS flags as a
  # safety net for direct `less` invocations.
  SHELL_ENV = {
    "TERM" => "dumb",
    "PAGER" => "cat",                   # Default pager for most Unix tools
    "LESS" => "-eFRX",                  # Safety net: make less auto-exit at EOF, no screen clear
    "GIT_PAGER" => "cat",              # Git checks this before PAGER
    "MANPAGER" => "cat",               # man pages
    "SYSTEMD_PAGER" => "",             # journalctl, systemctl (empty = disable)
    "BAT_PAGER" => "cat",             # bat (cat alternative)
    "AWS_PAGER" => "",                 # AWS CLI v2 (empty = disable)
    "PSQL_PAGER" => "cat",            # PostgreSQL psql
    "GIT_TERMINAL_PROMPT" => "0"       # Fail immediately instead of prompting for credentials
  }.freeze

  # Boots the user's login shell just long enough to source their profile
  # (/etc/profile, ~/.zprofile, ~/.bash_profile, ~/.zshenv — whichever
  # applies), then +exec+s a bare +bash+ that handles our command stream.
  #
  # Sourcing profile is what makes the agent see the same PATH, tool
  # locations, and env vars the user has in their own terminal. Handing off
  # to a bare +bash+ afterwards avoids the mess that comes with attaching a
  # real interactive shell to a PTY — prompts, line editors, syntax
  # highlighting, bracketed paste, and title-setting escapes would all
  # corrupt our marker-based output parsing.
  #
  # {SHELL_ENV} still merges on top to keep pagers and credential prompts
  # from hanging the PTY.
  def spawn_shell
    @pty_stdout, @pty_stdin, @pid = PTY.spawn(SHELL_ENV, self.class.login_shell, "-l", "-c", BARE_SHELL_EXEC)
    # Disable terminal echo via termios before the shell can echo our commands.
    # This is instant (kernel-level), unlike stty -echo which races with input.
    @pty_stdin.echo = false
  end

  # Payload handed to the login shell via +-c+. Replaces the login shell's
  # process with a bare bash so the user's profile env carries forward, but
  # the interactive shell machinery (ZLE, prompts, syntax highlighting) does
  # not. Must be bash specifically — the command stream relies on bash-safe
  # POSIX syntax, and the +--norc --noprofile+ flags are bash-specific.
  BARE_SHELL_EXEC = "exec bash --norc --noprofile"

  def start_stderr_reader
    @stderr_mutex = Mutex.new
    @stderr_buffer = []
    @stderr_bytes = 0
    @stderr_truncated = false
    @max_output_bytes = Anima::Settings.max_output_bytes
    @stderr_thread = Thread.new do
      max_bytes = @max_output_bytes
      File.open(@fifo_path, "r") do |fifo|
        while (line = fifo.gets)
          cleaned = line.chomp.delete("\r")
          @stderr_mutex.synchronize do
            if @stderr_bytes < max_bytes
              @stderr_buffer << cleaned
              @stderr_bytes += cleaned.bytesize
            else
              @stderr_truncated = true
            end
          end
        end
      end
    rescue Errno::ENOENT, IOError
      # FIFO was cleaned up or closed
    end
  end

  # With echo already off (set in spawn_shell), only command output appears.
  # The initial bash prompt merges with the marker output on one gets line.
  def init_shell
    marker = "__ANIMA_INIT_#{SecureRandom.hex(8)}__"
    @pty_stdin.puts "PS1=''"
    @pty_stdin.puts "exec 2>#{@fifo_path}"
    @pty_stdin.puts "echo '#{marker}'"
    unless consume_until(marker, deadline: monotonic_now + 10)
      raise IOError, "Shell initialization timed out"
    end
  end

  def execute_in_pty(command, timeout: nil, interrupt_check: nil)
    clear_stderr
    marker = "__ANIMA_#{SecureRandom.hex(8)}__"
    timeout ||= Anima::Settings.command_timeout
    deadline = monotonic_now + timeout

    @pty_stdin.puts "#{command}; __anima_ec=$?; echo; echo '#{marker}' $__anima_ec"

    stdout, exit_code = read_until_marker(marker, deadline: deadline, interrupt_check: interrupt_check)

    if exit_code == :interrupted
      recover_shell
      update_pwd
      stderr = drain_stderr
      return {
        interrupted: true,
        stdout: truncate(stdout),
        stderr: truncate(stderr)
      }
    end

    if exit_code.nil?
      recover_shell
      stderr = drain_stderr
      parts = ["Command timed out after #{timeout} seconds."]
      parts << "Partial stdout:\n#{truncate(stdout)}" unless stdout.empty?
      parts << "stderr:\n#{truncate(stderr)}" unless stderr.empty?
      return {error: parts.join("\n\n")}
    end

    env_summary = update_environment
    stderr = drain_stderr

    result = {
      stdout: truncate(stdout),
      stderr: truncate(stderr),
      exit_code: exit_code
    }
    result[:env_summary] = env_summary if env_summary
    result
  rescue Errno::EIO, IOError
    @alive = false
    {error: "Shell session terminated unexpectedly"}
  rescue => error # rubocop:disable Lint/RescueException -- LLM must always get a result hash, never a stack trace
    {error: "#{error.class}: #{error.message}"}
  end

  # Reads lines from the PTY until the marker appears.
  #
  # @param marker [String] unique marker to detect command completion
  # @param deadline [Float] monotonic clock deadline
  # @param interrupt_check [Proc, nil] callable returning truthy on user interrupt
  # @return [Array(String, Integer)] stdout and exit code on success
  # @return [Array(String, Symbol)] partial stdout and +:interrupted+ on user interrupt
  # @return [Array(String, nil)] partial stdout and nil exit code on timeout
  def read_until_marker(marker, deadline:, interrupt_check: nil)
    lines = []
    exit_code = nil
    check_interval = interrupt_check ? [Anima::Settings.interrupt_check_interval, 0.5].max : nil

    loop do
      line = gets_with_deadline(deadline, interrupt_check: interrupt_check, check_interval: check_interval)

      if line == :interrupted
        exit_code = :interrupted
        break
      end

      break if line.nil?

      line = line.chomp.delete("\r")

      if line.include?(marker)
        exit_code = line.split.last.to_i
        break
      end

      lines << line
    end

    # Strip trailing empty line added by our separator echo
    lines.pop if lines.last == ""

    [lines.join("\n"), exit_code]
  end

  # Reads and discards PTY output until the marker appears or deadline expires.
  #
  # @param marker [String] unique marker to wait for
  # @param deadline [Float] monotonic clock deadline
  # @return [Boolean] true if marker was found, false if deadline expired
  # @raise [Errno::EIO] when the PTY child process has exited
  # @raise [IOError] when the PTY file descriptor is closed
  def consume_until(marker, deadline:)
    loop do
      line = gets_with_deadline(deadline)
      return false if line.nil?
      return true if line.chomp.delete("\r").include?(marker)
    end
  end

  # Reads a single line from the PTY, respecting a deadline.
  # Caller must hold @mutex — @read_buffer is not independently synchronized.
  #
  # Uses IO.select for safe, non-interruptive timeout handling instead of
  # Timeout.timeout (which uses Thread.raise that can corrupt mutex state
  # and leave resources inconsistent).
  #
  # When +interrupt_check+ is provided, IO.select uses a shorter timeout
  # (capped at {Anima::Settings.interrupt_check_interval}) and polls the
  # callback between iterations. Returns +:interrupted+ when the callback
  # fires, allowing the caller to send Ctrl+C and return partial output.
  #
  # @param deadline [Float] monotonic clock deadline
  # @param interrupt_check [Proc, nil] callable returning truthy on user interrupt
  # @param check_interval [Float, nil] resolved interrupt check interval (seconds);
  #   pre-computed by the caller to avoid re-reading Settings on every line
  # @return [String] line including trailing newline
  # @return [:interrupted] when user interrupt detected
  # @return [nil] if deadline expired
  # @raise [Errno::EIO] when the PTY child process exits (Linux)
  # @raise [IOError] when the PTY file descriptor is closed
  def gets_with_deadline(deadline, interrupt_check: nil, check_interval: nil)
    loop do
      if (idx = @read_buffer.index("\n"))
        return @read_buffer.slice!(0..idx)
      end

      remaining = deadline - monotonic_now
      return nil if remaining <= 0

      select_timeout = check_interval ? [remaining, check_interval].min : remaining

      ready = IO.select([@pty_stdout], nil, nil, select_timeout)

      if ready
        begin
          @read_buffer << @pty_stdout.read_nonblock(4096)
        rescue IO::WaitReadable
          # Spurious wakeup from IO.select — retry
        end
      end

      return :interrupted if interrupt_check&.call
    end
  end

  # Sends Ctrl+C and drains leftover output after a timeout or user interrupt.
  # If recovery fails, marks the session as dead (will be respawned on next run).
  #
  # @return [void]
  # @raise [Errno::EIO] when the PTY child process has exited
  # @raise [IOError] when the PTY file descriptor is closed
  def recover_shell
    @pty_stdin.write("\x03")
    sleep 0.1
    marker = "__ANIMA_RECOVER_#{SecureRandom.hex(8)}__"
    @pty_stdin.puts "echo '#{marker}'"
    recovered = consume_until(marker, deadline: monotonic_now + 3)
    @alive = false unless recovered
  rescue Errno::EIO, IOError
    @alive = false
  end

  def clear_stderr
    @stderr_mutex.synchronize do
      @stderr_buffer.clear
      @stderr_bytes = 0
      @stderr_truncated = false
    end
  end

  def drain_stderr
    # Allow FIFO reader thread time to flush kernel buffers into @stderr_buffer.
    # Without this, stderr arriving just before the marker may be missed.
    sleep 0.01
    @stderr_mutex.synchronize do
      result = @stderr_buffer.join("\n")
      truncated = @stderr_truncated
      @stderr_buffer.clear
      @stderr_bytes = 0
      @stderr_truncated = false
      truncated ? result + "\n\n[Truncated: output exceeded #{@max_output_bytes} bytes]" : result
    end
  end

  # Captures the initial environment snapshot so the first real Bash call
  # can diff against the actual shell state rather than a blank sentinel
  # whose nil pwd would always trigger a "location changed" report.
  #
  # Sets {#env_snapshot} to a real snapshot of the current pwd, git branch,
  # repo, and project files. Called within {#start} after {#update_pwd}
  # and before the session is marked alive.
  #
  # @return [void]
  def seed_env_snapshot
    @env_snapshot = take_env_snapshot(EnvironmentSnapshot.blank)
  end

  # Snapshots the shell's environment and returns a natural-language summary
  # of what changed since the last snapshot. The agent discovers its
  # environment through these summaries in Bash tool responses.
  #
  # Each call only mentions what changed. Returns nil when nothing did.
  #
  # @return [String, nil] human-readable summary of environment changes
  def update_environment
    update_pwd
    previous = @env_snapshot || EnvironmentSnapshot.blank
    @env_snapshot = take_env_snapshot(previous)
    describe_env_changes(previous, @env_snapshot)
  end

  # Reads the shell's current working directory via the /proc filesystem.
  # @note Linux-only. Falls back silently on other platforms or if the
  #   process has exited.
  def update_pwd
    @pwd = File.readlink("/proc/#{@pid}/cwd")
  rescue Errno::ENOENT, Errno::EACCES
    # Process exited or no access — @pwd retains its previous value
  end

  # Captures the current environment as an immutable snapshot.
  # Re-detects git state on every call (branch can change without cd).
  # Re-scans project files only when the working directory changed.
  #
  # @param previous [EnvironmentSnapshot] the last known snapshot
  # @return [EnvironmentSnapshot]
  def take_env_snapshot(previous)
    branch, repo = detect_git
    files = (@pwd != previous.pwd) ? scan_project_files : previous.project_files

    EnvironmentSnapshot.new(pwd: @pwd, branch: branch, repo: repo, project_files: files)
  end

  # Detects git branch and repo name for the current working directory.
  #
  # @return [Array(String, String)] branch and repo name
  # @return [Array(nil, nil)] when not inside a git repository
  def detect_git
    return [nil, nil] unless @pwd

    _, status = Open3.capture2("git", "-C", @pwd, "rev-parse", "--is-inside-work-tree", err: File::NULL)
    return [nil, nil] unless status.success?

    branch = detect_git_branch
    repo = detect_git_repo
    [branch, repo]
  rescue Errno::ENOENT
    [nil, nil]
  end

  # @return [String, nil] current branch name
  def detect_git_branch
    output, = Open3.capture2("git", "-C", @pwd, "rev-parse", "--abbrev-ref", "HEAD", err: File::NULL)
    output.strip.presence
  end

  # @return [String, nil] "owner/repo" extracted from the origin remote
  def detect_git_repo
    output, = Open3.capture2("git", "-C", @pwd, "remote", "get-url", "origin", err: File::NULL)
    remote = output.strip
    return unless remote.present?

    extract_repo_name(remote)
  end

  # Scans for well-known project files in the current working directory.
  #
  # @return [Array<String>] sorted relative paths
  def scan_project_files
    return [] unless @pwd

    base = Pathname.new(@pwd)
    whitelist = Anima::Settings.project_files_whitelist
    max_depth = Anima::Settings.project_files_max_depth

    patterns = whitelist.product((0..max_depth).to_a).map do |filename, depth|
      File.join(@pwd, Array.new(depth, "*"), filename)
    end

    patterns.flat_map { |pattern| Dir.glob(pattern) }
      .map { |path| Pathname.new(path).relative_path_from(base).to_s }
      .sort
      .uniq
  end

  # Extracts owner/repo from a Git remote URL (SSH or HTTPS).
  #
  # @param remote_url [String] SSH or HTTPS remote URL
  # @return [String] "owner/repo" path
  def extract_repo_name(remote_url)
    path = if remote_url.match?(%r{\A\w+://})
      URI.parse(remote_url).path
    else
      remote_url.split(":").last
    end
    path.delete_prefix("/").delete_suffix(".git")
  rescue URI::InvalidURIError
    remote_url
  end

  # ─── Environment change description ──────────────────────────────

  # Builds a natural-language summary describing what changed between two
  # environment snapshots. Returns nil when nothing changed.
  #
  # @param old_snap [EnvironmentSnapshot]
  # @param new_snap [EnvironmentSnapshot]
  # @return [String, nil]
  def describe_env_changes(old_snap, new_snap)
    parts = []
    parts << describe_location_change(old_snap, new_snap)
    parts << describe_project_files(old_snap, new_snap)
    parts.compact!
    parts.empty? ? nil : parts.join("\n")
  end

  # @return [String, nil] location/branch change line
  def describe_location_change(old_snap, new_snap)
    if new_snap.pwd != old_snap.pwd
      format_full_location(new_snap)
    elsif new_snap.branch != old_snap.branch && new_snap.branch
      "Branch changed to #{new_snap.branch}."
    end
  end

  # @return [String, nil] project files line
  def describe_project_files(old_snap, new_snap)
    return unless new_snap.project_files.any?
    return unless new_snap.pwd != old_snap.pwd || new_snap.project_files != old_snap.project_files

    "Project has instructions in #{new_snap.project_files.join(", ")}."
  end

  # Formats the full location line for display in tool responses.
  #
  # @param snap [EnvironmentSnapshot]
  # @return [String]
  def format_full_location(snap)
    parts = ["You are now in #{snap.pwd}"]
    if snap.repo && snap.branch
      parts << ", git repo #{snap.repo} on branch #{snap.branch}"
    elsif snap.branch
      parts << " on branch #{snap.branch}"
    end
    parts.join + "."
  end

  def truncate(output)
    max_bytes = @max_output_bytes
    output = output.dup.force_encoding("UTF-8").scrub

    return output if output.bytesize <= max_bytes

    output.byteslice(0, max_bytes)
      .scrub +
      "\n\n[Truncated: output exceeded #{max_bytes} bytes]"
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Unconditionally cleans up all shell resources (PTY, FIFO, child process).
  # Does NOT short-circuit when @alive is already false — this ensures leaked
  # processes are reaped even after failed recovery marked the session dead.
  #
  # @return [void]
  def teardown
    @alive = false
    @read_buffer = +""

    if @pid
      begin
        pgid = Process.getpgid(@pid)
        Process.kill("TERM", -pgid)
      rescue Errno::ESRCH, Errno::EPERM
        # Process group already gone
      end
    end

    begin
      @pty_stdin&.close
    rescue IOError
      # Already closed
    end

    begin
      @pty_stdout&.close
    rescue IOError
      # Already closed
    end

    begin
      @stderr_thread&.join(1)
      @stderr_thread&.kill
    rescue ThreadError
      # Thread already dead
    end

    File.delete(@fifo_path) if @fifo_path && File.exist?(@fifo_path)

    if @pid
      begin
        # Non-blocking reap with SIGKILL fallback if process doesn't exit in time
        deadline = monotonic_now + 2
        loop do
          _, status = Process.wait2(@pid, Process::WNOHANG)
          break if status
          if monotonic_now > deadline
            Process.kill("KILL", @pid)
            Process.wait(@pid)
            break
          end
          sleep 0.05
        end
      rescue Errno::ECHILD, Errno::ESRCH
        # Already reaped
      end

      @pid = nil
    end
  end
end
