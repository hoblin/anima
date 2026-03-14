# frozen_string_literal: true

require "mcp"

module Mcp
  # Manages MCP client connections and registers their tools with
  # {Tools::Registry}. Each configured server (HTTP or stdio) gets
  # a dedicated {MCP::Client} instance. Tool lists are fetched once
  # during registration and cached in the registry — subsequent LLM
  # turns reuse the same tool set without re-querying servers.
  #
  # Connection failures are logged and skipped — a misconfigured or
  # unavailable server does not prevent other servers or built-in
  # tools from working.
  #
  # @example
  #   manager = Mcp::ClientManager.new
  #   manager.register_tools(registry)
  class ClientManager
    # @param config [Mcp::Config] injectable config for testing
    def initialize(config: Config.new)
      @config = config
    end

    # Connects to all configured MCP servers and registers their tools
    # in the given registry. Returns warnings for servers that failed
    # to load so the caller can surface them to the user.
    #
    # @param registry [Tools::Registry] the registry to add tools to
    # @return [Array<String>] warning messages for servers that failed
    def register_tools(registry)
      warnings = []
      register_transport_tools(@config.http_servers, registry, warnings) { |server| build_http_client(server) }
      register_transport_tools(@config.stdio_servers, registry, warnings) { |server| build_stdio_client(server) }
      @config.warnings + warnings
    end

    private

    # Iterates server configs, builds a client for each via the block,
    # and registers the server's tools. Failures are logged and collected.
    #
    # @param servers [Array<Hash>] server configs from {Mcp::Config}
    # @param registry [Tools::Registry] registry to register tools in
    # @param warnings [Array<String>] collects failure messages
    # @yield [server] block that builds an {MCP::Client} for the server
    def register_transport_tools(servers, registry, warnings)
      servers.each do |server|
        client = yield(server)
        register_server_tools(server[:name], client, registry)
      rescue => error
        message = "MCP: failed to load tools from #{server[:name]}: #{error.message}"
        Rails.logger.warn(message)
        warnings << message
      end
    end

    # Fetches tools from an MCP client and registers them with
    # namespaced names in the registry.
    #
    # @param server_name [String] server name for tool namespacing
    # @param client [MCP::Client] connected MCP client
    # @param registry [Tools::Registry] registry to register tools in
    def register_server_tools(server_name, client, registry)
      count = client.tools.map { |mcp_tool|
        Tools::McpTool.new(server_name: server_name, mcp_client: client, mcp_tool: mcp_tool)
      }.each { |wrapper| registry.register(wrapper) }.size

      Rails.logger.info("MCP: registered #{count} tools from #{server_name}")
    end

    # @param server [Hash] server config with +:url+ and +:headers+
    # @return [MCP::Client]
    def build_http_client(server)
      transport = MCP::Client::HTTP.new(url: server[:url], headers: server[:headers])
      MCP::Client.new(transport: transport)
    end

    # @param server [Hash] server config with +:command+, +:args+, +:env+
    # @return [MCP::Client]
    def build_stdio_client(server)
      transport = StdioTransport.new(command: server[:command], args: server[:args], env: server[:env])
      MCP::Client.new(transport: transport)
    end
  end
end
