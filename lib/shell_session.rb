# frozen_string_literal: true

require "io/console"
require "pty"
require "securerandom"
require "shellwords"

# Persistent shell session backed by a PTY with FIFO-based stderr separation.
# Commands share working directory, environment variables, and shell history
# within a conversation. Multiple tools share the same session.
#
# Auto-recovers from timeouts and crashes: if the shell dies, the next command
# transparently respawns a fresh shell and restores the working directory.
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

  # @param session_id [Integer, String] unique identifier for logging/diagnostics
  def initialize(session_id:)
    @session_id = session_id
    @mutex = Mutex.new
    @fifo_path = File.join(Dir.tmpdir, "anima-stderr-#{Process.pid}-#{SecureRandom.hex(8)}")
    @alive = false
    @finalized = false
    @pwd = nil
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
  # @return [Hash] with :stdout, :stderr, :exit_code keys on success
  # @return [Hash] with :error key on failure
  def run(command, timeout: nil)
    @mutex.synchronize do
      return {error: "Shell session is not running"} if @finalized
      restart unless @alive
      execute_in_pty(command, timeout: timeout)
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

  def spawn_shell
    @pty_stdout, @pty_stdin, @pid = PTY.spawn(
      SHELL_ENV,
      "bash", "--norc", "--noprofile"
    )
    # Disable terminal echo via termios before bash can echo our commands.
    # This is instant (kernel-level), unlike stty -echo which races with input.
    @pty_stdin.echo = false
  end

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

  def execute_in_pty(command, timeout: nil)
    clear_stderr
    marker = "__ANIMA_#{SecureRandom.hex(8)}__"
    timeout ||= Anima::Settings.command_timeout
    deadline = monotonic_now + timeout

    @pty_stdin.puts "#{command}; __anima_ec=$?; echo; echo '#{marker}' $__anima_ec"

    stdout, exit_code = read_until_marker(marker, deadline: deadline)

    if exit_code.nil?
      recover_from_timeout
      stderr = drain_stderr
      parts = ["Command timed out after #{timeout} seconds."]
      parts << "Partial stdout:\n#{truncate(stdout)}" unless stdout.empty?
      parts << "stderr:\n#{truncate(stderr)}" unless stderr.empty?
      return {error: parts.join("\n\n")}
    end

    update_pwd
    stderr = drain_stderr

    {
      stdout: truncate(stdout),
      stderr: truncate(stderr),
      exit_code: exit_code
    }
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
  # @return [Array(String, Integer)] stdout and exit code on success
  # @return [Array(String, nil)] partial stdout and nil exit code on timeout
  def read_until_marker(marker, deadline:)
    lines = []
    exit_code = nil

    loop do
      line = gets_with_deadline(deadline)
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
  # @param deadline [Float] monotonic clock deadline
  # @return [String] line including trailing newline
  # @return [nil] if deadline expired
  # @raise [Errno::EIO] when the PTY child process exits (Linux)
  # @raise [IOError] when the PTY file descriptor is closed
  def gets_with_deadline(deadline)
    loop do
      if (idx = @read_buffer.index("\n"))
        return @read_buffer.slice!(0..idx)
      end

      remaining = deadline - monotonic_now
      return nil if remaining <= 0

      ready = IO.select([@pty_stdout], nil, nil, remaining)
      return nil unless ready

      begin
        @read_buffer << @pty_stdout.read_nonblock(4096)
      rescue IO::WaitReadable
        # Spurious wakeup from IO.select — retry
      end
    end
  end

  # Sends Ctrl+C to interrupt the running command and drains leftover output.
  # If recovery fails, marks the session as dead (will be respawned on next run).
  #
  # @return [void]
  # @raise [Errno::EIO] when the PTY child process has exited
  # @raise [IOError] when the PTY file descriptor is closed
  def recover_from_timeout
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

  # Reads the shell's current working directory via the /proc filesystem.
  # @note Linux-only. Falls back silently on other platforms or if the
  #   process has exited.
  def update_pwd
    @pwd = File.readlink("/proc/#{@pid}/cwd")
  rescue Errno::ENOENT, Errno::EACCES
    # Process exited or no access — @pwd retains its previous value
  end

  def truncate(output)
    max_bytes = @max_output_bytes
    return output if output.bytesize <= max_bytes

    output.byteslice(0, max_bytes)
      .force_encoding("UTF-8")
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
