# frozen_string_literal: true

require "mcp"

module Mcp
  # Connects to MCP servers and registers their tools with
  # {Tools::Registry}. Each configured server (HTTP or stdio) is
  # connected on first use and the resulting tool wrappers are cached
  # for the worker's lifetime — so {Tools::Registry.build}, which fires
  # per job, reuses the same MCP clients instead of respawning a fresh
  # subprocess per server per job (issue #469).
  #
  # Spawned stdio server processes are reaped on worker exit by
  # {Mcp::StdioTransport.cleanup_all} (registered as an at_exit hook).
  #
  # Connection failures are logged and skipped — a misconfigured or
  # unavailable server does not prevent other servers or built-in tools
  # from working.
  #
  # @example
  #   Mcp::ClientManager.shared.register_tools(registry)
  class ClientManager
    # Process-wide shared instance. Lazily constructed on first call.
    # @return [Mcp::ClientManager]
    def self.shared
      @shared ||= new
    end

    # @param config [Mcp::Config] injectable config for testing
    def initialize(config: Config.new(logger: Rails.logger))
      @config = config
    end

    # Connects to every configured MCP server on first call, caches the
    # resulting tool wrappers, and registers them in the given registry.
    # Subsequent calls reuse the cache — no respawn, no extra
    # +tools/list+ round-trip.
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
      register_transport(@config.http_servers) { |server| build_http_client(server) }
      register_transport(@config.stdio_servers) { |server| build_stdio_client(server) }
    end

    # Iterates server configs, builds a client for each via the block,
    # caches the resulting tool wrappers. Failures are logged and
    # collected as warnings.
    def register_transport(servers)
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
