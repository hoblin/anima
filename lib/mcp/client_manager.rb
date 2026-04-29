# frozen_string_literal: true

require "mcp"

module Mcp
  # Connects to MCP servers and registers their tools with
  # {Tools::Registry}. Each configured server (HTTP or stdio) gets a
  # dedicated {MCP::Client} instance, cached for the worker's
  # lifetime. Connection failures are logged and skipped — a
  # misconfigured or unavailable server does not prevent other servers
  # or built-in tools from working.
  #
  # Spawned stdio processes are reaped on worker exit via
  # {Mcp::StdioTransport.cleanup_all}.
  #
  # The cache is built once on the first {#register_tools} call and
  # never invalidated; edits to +mcp.toml+ require a worker restart.
  #
  # @example
  #   Mcp::ClientManager.shared.register_tools(registry)
  class ClientManager
    # Lazily-instantiated process-wide manager. Production code should
    # call {.shared}; {.new} is reserved for tests and internal use.
    # @return [Mcp::ClientManager]
    def self.shared
      @shared ||= new
    end

    # @param config [Mcp::Config] injectable config for testing
    def initialize(config: Config.new(logger: Rails.logger))
      @config = config
    end

    # Connects to every configured MCP server on first call, caches
    # the resulting tool wrappers, and registers them in the given
    # registry.
    #
    # @param registry [Tools::Registry] the registry to add tools to
    # @return [Array<String>] warning messages from configuration plus
    #   any per-server load failures
    def register_tools(registry)
      load_servers if @wrappers.nil?
      @wrappers.each { |wrapper| registry.register(wrapper) }
      @config.warnings + @warnings
    end

    private

    def load_servers
      @wrappers = []
      @warnings = []
      register_transport_tools(@config.http_servers) { |server| build_http_client(server) }
      register_transport_tools(@config.stdio_servers) { |server| build_stdio_client(server) }
    end

    def register_transport_tools(servers)
      servers.each do |server|
        client = yield(server)
        wrappers = client.tools.map { |mcp_tool|
          Tools::McpTool.new(server_name: server[:name], mcp_client: client, mcp_tool: mcp_tool)
        }
        @wrappers.concat(wrappers)
        Rails.logger.info("MCP: registered #{wrappers.size} tools from #{server[:name]}")
      rescue => error
        message = "MCP: failed to load tools from #{server[:name]}: #{error.message}"
        Rails.logger.warn(message)
        @warnings << message
      end
    end

    def build_http_client(server)
      transport = MCP::Client::HTTP.new(url: server[:url], headers: server[:headers])
      MCP::Client.new(transport: transport)
    end

    def build_stdio_client(server)
      transport = StdioTransport.new(command: server[:command], args: server[:args], env: server[:env])
      MCP::Client.new(transport: transport)
    end
  end
end
