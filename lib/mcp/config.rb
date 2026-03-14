# frozen_string_literal: true

require "toml-rb"

module Mcp
  # Parses MCP server configuration from a TOML file at {DEFAULT_PATH}.
  # Supports environment variable interpolation via `${VAR_NAME}` syntax
  # in any string value. Only HTTP transport servers are returned;
  # other transports (e.g. stdio) are silently skipped for future phases.
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
  class Config
    DEFAULT_PATH = File.expand_path("~/.anima/mcp.toml")

    # Pattern matching `${VAR_NAME}` for environment variable interpolation.
    ENV_VAR_PATTERN = /\$\{(\w+)\}/

    # @param path [String] path to the TOML config file
    def initialize(path: DEFAULT_PATH)
      @path = path
    end

    # Returns HTTP server configurations from the config file.
    # Non-HTTP transports are silently skipped. Missing or empty config
    # file returns an empty array without error.
    #
    # @return [Array<Hash>] server configs with :name, :url, :headers keys
    # @raise [KeyError] if a referenced environment variable is not set
    def http_servers
      return [] unless File.exist?(@path)

      config = TomlRB.load_file(@path)
      servers = config["servers"] || {}

      servers.filter_map do |name, settings|
        next unless settings["transport"] == "http"

        url = settings["url"]
        next unless url

        {
          name: name,
          url: interpolate_env(url),
          headers: interpolate_headers(settings["headers"] || {})
        }
      end
    end

    private

    # Replaces `${VAR_NAME}` placeholders with environment variable values.
    #
    # @param value [String] string potentially containing placeholders
    # @return [String] interpolated string
    # @raise [KeyError] if a referenced variable is not set
    def interpolate_env(value)
      value.gsub(ENV_VAR_PATTERN) { ENV.fetch(::Regexp.last_match(1)) }
    end

    # Interpolates environment variables in all header values.
    #
    # @param headers [Hash<String, String>] header name-value pairs
    # @return [Hash<String, String>] headers with interpolated values
    def interpolate_headers(headers)
      headers.transform_values { |value| interpolate_env(value) }
    end
  end
end
