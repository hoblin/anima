# frozen_string_literal: true

require "mcp"

module Mcp
  # Manages MCP client connections and registers their tools with
  # {Tools::Registry}. Each configured HTTP server gets a dedicated
  # {MCP::Client} instance. Tool lists are fetched once during
  # registration and cached in the registry — subsequent LLM turns
  # reuse the same tool set without re-querying servers.
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

    # Connects to all configured HTTP MCP servers and registers
    # their tools in the given registry.
    #
    # @param registry [Tools::Registry] the registry to add tools to
    # @return [void]
    def register_tools(registry)
      @config.http_servers.each do |server|
        register_server_tools(server, registry)
      rescue => error
        Rails.logger.warn("MCP: failed to load tools from #{server[:name]} " \
                          "(#{server[:url]}): #{error.message}")
      end
    end

    private

    # Connects to a single MCP server and registers all its tools.
    #
    # @param server [Hash] server config with :name, :url, :headers
    # @param registry [Tools::Registry] registry to register tools in
    def register_server_tools(server, registry)
      server_name = server[:name]
      count = fetch_and_wrap_tools(server_name, server)
        .each { |wrapper| registry.register(wrapper) }
        .size

      Rails.logger.info("MCP: registered #{count} tools from #{server_name}")
    end

    # Fetches tools from an MCP server and wraps them for registry use.
    #
    # @param server_name [String] server name for tool namespacing
    # @param server [Hash] server config with :url and :headers
    # @return [Array<Tools::McpTool>] wrapped tools ready for registration
    def fetch_and_wrap_tools(server_name, server)
      client = build_client(server)

      client.tools.map do |mcp_tool|
        Tools::McpTool.new(server_name: server_name, mcp_client: client, mcp_tool: mcp_tool)
      end
    end

    # Creates an MCP client with HTTP transport for the given server.
    # The MCP gem's HTTP transport does not yet support timeout configuration —
    # Faraday defaults apply. A hanging server will block until Faraday times out.
    #
    # @param server [Hash] server config with :url and :headers
    # @return [MCP::Client]
    def build_client(server)
      transport = MCP::Client::HTTP.new(url: server[:url], headers: server[:headers])
      MCP::Client.new(transport: transport)
    end
  end
end
