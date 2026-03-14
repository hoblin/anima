# frozen_string_literal: true

require "toml-rb"

module Mcp
  # Parses MCP server configuration from a TOML file at {DEFAULT_PATH}.
  # Supports HTTP and stdio transports. Environment variable interpolation
  # via +${VAR_NAME}+ syntax works in any string value.
  #
  # @example Config file format (~/.anima/mcp.toml)
  #   [servers.mythonix]
  #   transport = "http"
  #   url = "http://localhost:3000/mcp/v2"
  #
  #   [servers.linear]
  #   transport = "http"
  #   url = "https://mcp.linear.app/mcp"
  #   headers = { Authorization = "Bearer ${LINEAR_API_KEY}" }
  #
  #   [servers.filesystem]
  #   transport = "stdio"
  #   command = "mcp-server-filesystem"
  #   args = ["--root", "/workspace"]
  #   env = { DEBUG = "true" }
  class Config
    DEFAULT_PATH = File.expand_path("~/.anima/mcp.toml")

    # Pattern matching `${VAR_NAME}` for environment variable interpolation.
    ENV_VAR_PATTERN = /\$\{(\w+)\}/

    # @param path [String] path to the TOML config file
    def initialize(path: DEFAULT_PATH)
      @path = path
    end

    # Returns HTTP server configurations from the config file.
    #
    # @return [Array<Hash>] server configs with +:name+, +:url+, +:headers+ keys
    def http_servers
      servers_by_transport("http") do |name, settings|
        url = settings["url"]
        unless url
          Rails.logger.warn("MCP: server '#{name}' has transport=http but no url — skipping")
          next
        end

        {
          name: name,
          url: interpolate_env(url),
          headers: interpolate_hash_values(settings["headers"] || {})
        }
      end
    end

    # Returns stdio server configurations from the config file.
    #
    # @return [Array<Hash>] server configs with +:name+, +:command+, +:args+, +:env+ keys
    def stdio_servers
      servers_by_transport("stdio") do |name, settings|
        command = settings["command"]
        unless command
          Rails.logger.warn("MCP: server '#{name}' has transport=stdio but no command — skipping")
          next
        end

        {
          name: name,
          command: interpolate_env(command),
          args: (settings["args"] || []).map { |arg| interpolate_env(arg) },
          env: interpolate_hash_values(settings["env"] || {})
        }
      end
    end

    private

    # Iterates servers matching a given transport type, yielding each
    # for transport-specific parsing. Returns an empty array if the
    # config file is missing or empty. Servers referencing unset
    # environment variables are skipped with a warning — one bad
    # server config must not prevent others from loading.
    #
    # @param transport [String] transport type to filter by ("http", "stdio")
    # @yield [name, settings] block that returns a parsed server hash or nil
    # @return [Array<Hash>] parsed server configs
    def servers_by_transport(transport)
      return [] unless File.exist?(@path)

      config = TomlRB.load_file(@path)
      servers = config["servers"] || {}

      servers.filter_map do |name, settings|
        next unless settings["transport"] == transport

        yield(name, settings)
      rescue KeyError => error
        Rails.logger.warn("MCP: server '#{name}' references unset env var #{error.message} — skipping")
        nil
      end
    end

    # Replaces +${VAR_NAME}+ placeholders with environment variable values.
    #
    # @param value [String] string potentially containing placeholders
    # @return [String] interpolated string
    # @raise [KeyError] if a referenced variable is not set
    def interpolate_env(value)
      value.gsub(ENV_VAR_PATTERN) { ENV.fetch(::Regexp.last_match(1)) }
    end

    # Interpolates environment variables in all values of a string hash.
    #
    # @param hash [Hash<String, String>] key-value pairs with potential placeholders
    # @return [Hash<String, String>] hash with interpolated values
    def interpolate_hash_values(hash)
      hash.transform_values { |value| interpolate_env(value) }
    end
  end
end
