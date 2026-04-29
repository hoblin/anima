# frozen_string_literal: true

require "mcp"

module Mcp
  # Manages MCP client connections and registers their tools with
  # {Tools::Registry}. Each configured server (HTTP or stdio) gets a
  # dedicated {MCP::Client} instance that persists for the worker
  # process's lifetime, in line with the MCP integration research note
  # (decision #11): stdio servers spawn lazily on first use and stay
  # alive across tool calls.
  #
  # The class-level {.shared} accessor returns a single instance per
  # process. {Tools::Registry.build} is called per job, but it pulls
  # tools from the shared manager, so each configured server is connected
  # exactly once per worker — not once per job — preventing the
  # subprocess accumulation reported in issue #469.
  #
  # Connection failures are logged and skipped — a misconfigured or
  # unavailable server does not prevent other servers or built-in tools
  # from working. Warnings collected during the initial load are returned
  # from the first {#register_tools} call so the caller can surface them
  # as system messages; subsequent calls return an empty array, since the
  # same warnings would otherwise be re-emitted on every job.
  #
  # @example Production use
  #   Mcp::ClientManager.shared.register_tools(registry)
  #
  # @example Test use with injected config
  #   manager = Mcp::ClientManager.new(config: fake_config)
  #   manager.register_tools(registry)
  class ClientManager
    class << self
      # Process-wide shared instance. Lazily constructed on first call.
      # @return [Mcp::ClientManager]
      def shared
        shared_mutex.synchronize { @shared ||= new }
      end

      # Tears down the shared instance, terminating all cached MCP server
      # connections and clearing cached tool wrappers. The next {.shared}
      # call rebuilds from scratch. Used at process shutdown and from
      # tests that need to isolate state.
      def reset!
        shared_mutex.synchronize do
          @shared&.shutdown
          @shared = nil
        end
      end

      private

      def shared_mutex
        @shared_mutex ||= Mutex.new
      end
    end

    # @param config [Mcp::Config] injectable config for testing
    def initialize(config: Config.new(logger: Rails.logger))
      @config = config
      @clients = {}
      @transports = {}
      @tool_wrappers = {}
      @warnings = []
      @loaded = false
      @warnings_consumed = false
      @load_mutex = Mutex.new
    end

    # Connects to every configured MCP server on first call (lazy load),
    # fetches their tool catalogs, and caches the connections. Subsequent
    # calls reuse the cache and just attach the cached tool wrappers to
    # the given registry — no respawn, no extra round-trip.
    #
    # The entire body runs under +@load_mutex+ so a concurrent {#shutdown}
    # cannot clear the cache mid-iteration.
    #
    # @param registry [Tools::Registry] the registry to add tools to
    # @return [Array<String>] warning messages from the initial load on
    #   the first call; an empty array on subsequent calls
    def register_tools(registry)
      @load_mutex.synchronize do
        load_servers unless @loaded
        @tool_wrappers.each_value do |wrappers|
          wrappers.each { |wrapper| registry.register(wrapper) }
        end
        consume_warnings
      end
    end

    # Tears down all cached MCP client connections, shutting down their
    # transports (which terminates any spawned stdio server processes).
    # After shutdown, the next {#register_tools} call will rebuild the
    # cache from configuration.
    def shutdown
      @load_mutex.synchronize do
        @transports.each_value do |transport|
          transport.shutdown if transport.respond_to?(:shutdown)
        end
        @clients.clear
        @transports.clear
        @tool_wrappers.clear
        @warnings.clear
        @warnings_consumed = false
        @loaded = false
      end
    end

    private

    def load_servers
      register_transport_tools(@config.http_servers) { |server| build_http_client(server) }
      register_transport_tools(@config.stdio_servers) { |server| build_stdio_client(server) }
      @loaded = true
    end

    # Iterates server configs, builds a client+transport for each via the
    # block, and registers the server's tools. Failures are logged and
    # collected as warnings.
    def register_transport_tools(servers)
      servers.each do |server|
        client, transport = yield(server)
        register_server_tools(server[:name], client, transport)
      rescue => error
        message = "MCP: failed to load tools from #{server[:name]}: #{error.message}"
        Rails.logger.warn(message)
        @warnings << message
      end
    end

    def register_server_tools(server_name, client, transport)
      wrappers = client.tools.map { |mcp_tool|
        Tools::McpTool.new(server_name: server_name, mcp_client: client, mcp_tool: mcp_tool)
      }
      @clients[server_name] = client
      @transports[server_name] = transport
      @tool_wrappers[server_name] = wrappers

      Rails.logger.info("MCP: registered #{wrappers.size} tools from #{server_name}")
    end

    def build_http_client(server)
      transport = MCP::Client::HTTP.new(url: server[:url], headers: server[:headers])
      [MCP::Client.new(transport: transport), transport]
    end

    def build_stdio_client(server)
      transport = StdioTransport.new(command: server[:command], args: server[:args], env: server[:env])
      [MCP::Client.new(transport: transport), transport]
    end

    def consume_warnings
      return [] if @warnings_consumed
      @warnings_consumed = true
      @config.warnings + @warnings
    end
  end
end
