# frozen_string_literal: true

require "json"
require "mcp"
require "open3"
require "timeout"

module Mcp
  # Client-side stdio transport for MCP servers that communicate via
  # JSON-RPC over stdin/stdout. Conforms to the MCP SDK transport contract
  # (+send_request(request:)+ → Hash) so it plugs into {MCP::Client}
  # identically to the built-in HTTP transport.
  #
  # Spawns the server process lazily on first request. If the process
  # crashes, the next request automatically respawns it. Thread-safe
  # via a mutex around the entire request/response cycle.
  #
  # @example
  #   transport = Mcp::StdioTransport.new(command: "linear-toon-mcp")
  #   client = MCP::Client.new(transport: transport)
  #   client.tools  # spawns process, sends tools/list, returns tools
  #
  # @see MCP::Client::HTTP the built-in HTTP transport this mirrors
  class StdioTransport
    # Seconds to wait for graceful SIGTERM shutdown before escalating to SIGKILL.
    GRACEFUL_SHUTDOWN_TIMEOUT = 2

    # @param command [String] executable to spawn (resolved via $PATH)
    # @param args [Array<String>] command-line arguments for the server process
    # @param env [Hash<String, String>] environment variables merged into
    #   the child process's inherited environment
    def initialize(command:, args: [], env: {})
      @command = command
      @args = args
      @env = env
      @mutex = Mutex.new
      @stdin = nil
      @stdout = nil
      @wait_thread = nil
    end

    # Sends a JSON-RPC request and returns the parsed response.
    # Spawns the server process on first call. If the process died
    # since the last call, respawns automatically.
    #
    # @param request [Hash] complete JSON-RPC request object with
    #   +:jsonrpc+, +:id+, +:method+, and optional +:params+ keys
    # @return [Hash] parsed JSON-RPC response (string keys)
    # @raise [MCP::Client::RequestHandlerError] on transport-level errors
    #   (process crash, invalid JSON, timeout, command not found)
    def send_request(request:)
      @mutex.synchronize do
        perform_request(request)
      end
    end

    # Terminates the server process and releases resources.
    # Safe to call multiple times — subsequent calls are no-ops.
    def shutdown
      @mutex.synchronize { stop_process }
      self.class.unregister(self)
    end

    # --- Class-level instance tracking for at_exit cleanup ---

    @instances = []
    @instances_mutex = Mutex.new

    class << self
      # @api private
      def register(instance)
        @instances_mutex.synchronize { @instances << instance }
      end

      # @api private
      def unregister(instance)
        @instances_mutex.synchronize { @instances.delete(instance) }
      end

      # Shuts down all tracked instances. Called automatically via +at_exit+.
      def cleanup_all
        @instances_mutex.synchronize do
          @instances.each { |instance| instance.send(:stop_process) }
          @instances.clear
        end
      end
    end

    at_exit { Mcp::StdioTransport.cleanup_all }

    private

    def perform_request(request)
      ensure_running
      write_request(request)
      read_response(request)
    rescue Errno::EPIPE, IOError => error
      stop_process
      raise_transport_error("Server process crashed: #{error.message}", request, error)
    rescue JSON::ParserError => error
      stop_process
      raise_transport_error("Invalid JSON from server: #{error.message}", request, error)
    rescue Timeout::Error
      stop_process
      raise_transport_error("No response within #{Anima::Settings.mcp_response_timeout}s", request)
    end

    def ensure_running
      return if alive?

      spawn_process
    end

    def alive?
      @wait_thread&.alive? || false
    end

    # +pgroup: true+ so {#terminate_process} can group-signal the
    # entire descendant tree — npm/npx wrappers leak their +node+
    # children otherwise.
    def spawn_process
      @stdin, @stdout, @wait_thread = Open3.popen2(@env, @command, *@args, pgroup: true)
      @stdin.set_encoding("UTF-8")
      @stdout.set_encoding("UTF-8")
      self.class.register(self)
    rescue Errno::ENOENT => error
      raise_transport_error("Command not found: #{@command}", {}, error)
    end

    def write_request(request)
      @stdin.puts(JSON.generate(request))
      @stdin.flush
    end

    # Reads lines from stdout until a JSON-RPC response matching the
    # request ID is found. Notifications (messages without a matching id)
    # are silently skipped — the MCP protocol allows servers to emit
    # them at any time.
    def read_response(request)
      request_id = (request[:id] || request["id"]).to_s

      Timeout.timeout(Anima::Settings.mcp_response_timeout) do
        loop do
          line = @stdout.gets
          raise IOError, "Server process closed stdout" if line.nil?

          parsed = JSON.parse(line)
          unless parsed.is_a?(Hash)
            raise JSON::ParserError, "Expected JSON object, got #{parsed.class}"
          end

          return parsed if parsed["id"].to_s == request_id
        end
      end
    end

    def stop_process
      close_pipes
      terminate_process
      @stdin = nil
      @stdout = nil
      @wait_thread = nil
    end

    def close_pipes
      @stdin&.close rescue IOError # rubocop:disable Style/RescueModifier
      @stdout&.close rescue IOError # rubocop:disable Style/RescueModifier
    end

    # Sends SIGTERM to the process group; escalates to SIGKILL on the
    # group after +GRACEFUL_SHUTDOWN_TIMEOUT+ seconds. Negative PID
    # signals the whole group (see {#spawn_process}).
    def terminate_process
      return unless @wait_thread

      pid = @wait_thread.pid
      begin
        Process.kill("TERM", -pid)
      rescue Errno::ESRCH, Errno::EPERM
        return
      end

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + GRACEFUL_SHUTDOWN_TIMEOUT
      loop do
        _, status = Process.wait2(pid, Process::WNOHANG)
        break if status
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          Process.kill("KILL", -pid) rescue Errno::ESRCH # rubocop:disable Style/RescueModifier
          Process.wait(pid) rescue Errno::ECHILD # rubocop:disable Style/RescueModifier
          break
        end
        sleep 0.05
      end
    rescue Errno::ECHILD, Errno::ESRCH
      # Already reaped
    end

    def raise_transport_error(message, request, original_error = nil)
      method = request[:method] || request["method"]
      params = request[:params] || request["params"]

      raise MCP::Client::RequestHandlerError.new(
        message,
        {method: method, params: params},
        error_type: :internal_error,
        original_error: original_error
      )
    end
  end
end
