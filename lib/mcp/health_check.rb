# frozen_string_literal: true

require "timeout"

module Mcp
  # Probes an MCP server to verify connectivity and count available tools.
  # Used by the CLI +list+ command to show server health status.
  #
  # @example
  #   result = Mcp::HealthCheck.call(name: "sentry", url: "https://mcp.sentry.dev/mcp", headers: {})
  #   result #=> { status: :connected, tools: 5 }
  class HealthCheck
    # Health check probe timeout in seconds. Balances responsiveness
    # (CLI shouldn't hang) vs. giving slow servers a fair chance.
    TIMEOUT = 5

    # @param server [Hash] interpolated server config with symbol keys
    #   (+:name+, +:url+/+:command+, and +:transport+)
    # @return [Hash] +{ status: :connected, tools: Integer }+ or
    #   +{ status: :failed, error: String }+
    def self.call(server)
      new(server).call
    end

    def initialize(server)
      @server = server
      @stdio_transport = nil
    end

    def call
      Timeout.timeout(TIMEOUT) { check }
    rescue Timeout::Error
      {status: :failed, error: "connection timeout"}
    rescue KeyError => key_error
      {status: :failed, error: "missing credential #{key_error.message}"}
    rescue => error
      {status: :failed, error: error.message}
    end

    private

    def check
      transport = @server[:transport]

      case transport
      when "http" then check_http
      when "stdio" then check_stdio
      else {status: :failed, error: "unknown transport '#{transport}'"}
      end
    end

    def check_http
      require "mcp"

      transport = MCP::Client::HTTP.new(url: @server[:url], headers: @server[:headers] || {})
      client = MCP::Client.new(transport: transport)
      tool_count = client.tools.size
      {status: :connected, tools: tool_count}
    end

    def check_stdio
      require "mcp"
      require_relative "stdio_transport"

      @stdio_transport = StdioTransport.new(
        command: @server[:command],
        args: @server[:args] || [],
        env: @server[:env] || {}
      )
      client = MCP::Client.new(transport: @stdio_transport)
      tool_count = client.tools.size
      {status: :connected, tools: tool_count}
    ensure
      @stdio_transport&.shutdown
    end
  end
end
