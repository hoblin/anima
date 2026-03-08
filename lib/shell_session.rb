# frozen_string_literal: true

require "io/console"
require "pty"
require "securerandom"
require "timeout"

# Persistent shell session backed by a PTY with FIFO-based stderr separation.
# Commands share working directory, environment variables, and shell history
# within a conversation. Multiple tools share the same session.
#
# @example
#   session = ShellSession.new(session_id: 42)
#   session.run("cd /tmp")
#   session.run("pwd")
#   # => {stdout: "/tmp", stderr: "", exit_code: 0}
#   session.finalize
class ShellSession
  COMMAND_TIMEOUT = 30
  MAX_OUTPUT_BYTES = 100_000

  # @return [String, nil] current working directory of the shell process
  attr_reader :pwd

  # @param session_id [Integer, String] unique identifier for logging/diagnostics
  def initialize(session_id:)
    @session_id = session_id
    @mutex = Mutex.new
    @fifo_path = File.join(Dir.tmpdir, "anima-stderr-#{Process.pid}-#{SecureRandom.hex(8)}")
    @alive = false
    @pwd = nil
    self.class.cleanup_orphans
    start
    self.class.register(self)
  end

  # Execute a command in the persistent shell.
  #
  # @param command [String] bash command to execute
  # @return [Hash] with :stdout, :stderr, :exit_code keys on success
  # @return [Hash] with :error key on failure
  def run(command)
    @mutex.synchronize do
      return {error: "Shell session is not running"} unless @alive
      execute_in_pty(command)
    end
  end

  # Clean up PTY, FIFO, and child process.
  def finalize
    @mutex.synchronize { shutdown }
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
        @sessions.each { |session| session.send(:shutdown) }
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

  def create_fifo
    File.mkfifo(@fifo_path)
  rescue Errno::EEXIST
    # FIFO already exists — reuse it
  end

  def spawn_shell
    @pty_stdout, @pty_stdin, @pid = PTY.spawn(
      {"TERM" => "dumb"},
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
    @stderr_thread = Thread.new do
      File.open(@fifo_path, "r") do |fifo|
        while (line = fifo.gets)
          cleaned = line.chomp.delete("\r")
          @stderr_mutex.synchronize do
            if @stderr_bytes < MAX_OUTPUT_BYTES
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
    consume_until(marker)
  end

  def execute_in_pty(command)
    clear_stderr
    marker = "__ANIMA_#{SecureRandom.hex(8)}__"

    Timeout.timeout(COMMAND_TIMEOUT) do
      # All on one line: run command, capture exit code, ensure newline
      # before marker so output without trailing newline doesn't merge.
      @pty_stdin.puts "#{command}; __anima_ec=$?; echo; echo '#{marker}' $__anima_ec"

      stdout, exit_code = read_until_marker(marker)
      update_pwd
      stderr = drain_stderr

      {
        stdout: truncate(stdout),
        stderr: truncate(stderr),
        exit_code: exit_code
      }
    end
  rescue Timeout::Error
    recover_from_timeout
    {error: "Command timed out after #{COMMAND_TIMEOUT} seconds"}
  rescue Errno::EIO
    @alive = false
    {error: "Shell session terminated unexpectedly"}
  rescue => error
    {error: "#{error.class}: #{error.message}"}
  end

  def read_until_marker(marker)
    lines = []
    exit_code = nil

    loop do
      line = @pty_stdout.gets
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

    [lines.join("\n"), exit_code || -1]
  end

  def consume_until(marker)
    loop do
      line = @pty_stdout.gets
      break if line.nil?
      break if line.chomp.delete("\r").include?(marker)
    end
  end

  # Sends Ctrl+C to interrupt the running command and drains leftover output.
  # If recovery fails, marks the session as dead.
  def recover_from_timeout
    @pty_stdin.write("\x03")
    sleep 0.1
    marker = "__ANIMA_RECOVER_#{SecureRandom.hex(8)}__"
    @pty_stdin.puts "echo '#{marker}'"
    Timeout.timeout(3) { consume_until(marker) }
  rescue Timeout::Error, Errno::EIO, IOError
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
      truncated ? result + "\n\n[Truncated: output exceeded #{MAX_OUTPUT_BYTES} bytes]" : result
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
    return output if output.bytesize <= MAX_OUTPUT_BYTES

    output.byteslice(0, MAX_OUTPUT_BYTES)
      .force_encoding("UTF-8")
      .scrub +
      "\n\n[Truncated: output exceeded #{MAX_OUTPUT_BYTES} bytes]"
  end

  def shutdown
    return unless @alive
    @alive = false

    begin
      pgid = Process.getpgid(@pid)
      Process.kill("TERM", -pgid)
    rescue Errno::ESRCH, Errno::EPERM
      # Process group already gone
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
      @stderr_thread&.kill
    rescue ThreadError
      # Thread already dead
    end

    File.delete(@fifo_path) if File.exist?(@fifo_path)

    begin
      # Non-blocking reap with SIGKILL fallback if process doesn't exit in time
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      loop do
        _, status = Process.wait2(@pid, Process::WNOHANG)
        break if status
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          Process.kill("KILL", @pid)
          Process.wait(@pid)
          break
        end
        sleep 0.05
      end
    rescue Errno::ECHILD, Errno::ESRCH
      # Already reaped
    end
  end
end
