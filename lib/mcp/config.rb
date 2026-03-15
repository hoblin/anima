# frozen_string_literal: true

require "fileutils"
require "toml-rb"

module Mcp
  # Reads and writes MCP server configuration from a TOML file at
  # {DEFAULT_PATH}. Supports HTTP and stdio transports. Secrets stored
  # in Rails encrypted credentials are interpolated via
  # +${credential:key_name}+ syntax in any string value.
  #
  # @example Config file format (~/.anima/mcp.toml)
  #   [servers.mythonix]
  #   transport = "http"
  #   url = "http://localhost:3000/mcp/v2"
  #
  #   [servers.linear]
  #   transport = "http"
  #   url = "https://mcp.linear.app/mcp"
  #   headers = { Authorization = "Bearer ${credential:linear_api_key}" }
  #
  #   [servers.filesystem]
  #   transport = "stdio"
  #   command = "mcp-server-filesystem"
  #   args = ["--root", "/workspace"]
  class Config
    DEFAULT_PATH = File.expand_path("~/.anima/mcp.toml")

    # Pattern matching `${credential:key_name}` for credential interpolation.
    CREDENTIAL_PATTERN = /\$\{credential:(\w+)\}/

    # Bare TOML keys: letters, digits, hyphens, underscores.
    VALID_NAME_PATTERN = /\A[A-Za-z0-9_-]+\z/

    # Warnings accumulated during parsing (missing credentials, invalid entries).
    # @return [Array<String>]
    attr_reader :warnings

    # @param path [String] path to the TOML config file
    # @param logger [#warn, nil] optional logger for warning output
    def initialize(path: DEFAULT_PATH, logger: nil)
      @path = path
      @logger = logger
      @warnings = []
      @config_cache = nil
    end

    # Returns all configured servers with raw (pre-interpolation) settings.
    # Intended for display in CLI commands where showing literal
    # +${credential:...}+ placeholders is more useful than resolved values.
    #
    # @return [Array<Hash>] servers with string keys from TOML plus +"name"+
    def all_servers
      servers = load_config["servers"] || {}
      servers.map { |name, settings| settings.merge("name" => name) }
    end

    # Adds a server entry to the configuration file.
    # Creates the file and parent directories if they don't exist.
    #
    # @param name [String] unique server identifier (letters, digits, hyphens, underscores)
    # @param settings [Hash<String, Object>] server configuration (transport, url/command, etc.)
    # @raise [ArgumentError] if name is invalid or already exists
    def add_server(name, settings)
      validate_name!(name)
      config = load_config
      servers = config["servers"] ||= {}

      raise ArgumentError, "server '#{name}' already exists" if servers.key?(name)

      servers[name] = settings
      write_config(config)
    end

    # Removes a server entry from the configuration file.
    #
    # @param name [String] server identifier to remove
    # @raise [ArgumentError] if server name not found
    def remove_server(name)
      config = load_config
      servers = config["servers"] || {}

      raise ArgumentError, "server '#{name}' not found" unless servers.key?(name)

      servers.delete(name)
      write_config(config)
    end

    # Returns HTTP server configurations from the config file.
    #
    # @return [Array<Hash>] server configs with +:name+, +:url+, +:headers+ keys
    def http_servers
      servers_by_transport("http") do |name, settings|
        url = settings["url"]
        unless url
          warn_and_skip("server '#{name}' has transport=http but no url")
          next
        end

        {
          name: name,
          url: interpolate_credentials(url),
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
          warn_and_skip("server '#{name}' has transport=stdio but no command")
          next
        end

        {
          name: name,
          command: interpolate_credentials(command),
          args: (settings["args"] || []).map { |arg| interpolate_credentials(arg) },
          env: interpolate_hash_values(settings["env"] || {})
        }
      end
    end

    private

    # Reads the TOML config file, returning an empty hash when missing.
    # Result is cached for the lifetime of this Config instance; mutating
    # callers (+add_server+, +remove_server+) invalidate the cache on write.
    #
    # @return [Hash] parsed TOML config
    def load_config
      @config_cache ||= if File.exist?(@path)
        TomlRB.load_file(@path)
      else
        {}
      end
    end

    # Serializes config hash to TOML and writes to disk.
    # Creates parent directories if needed. Sets restrictive permissions
    # since config may contain API keys or auth headers.
    def write_config(config)
      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, TomlRB.dump(config))
      File.chmod(0o600, @path)
      @config_cache = nil
    end

    # @raise [ArgumentError] if name contains characters invalid for TOML bare keys
    def validate_name!(name)
      return if name.match?(VALID_NAME_PATTERN)

      raise ArgumentError,
        "invalid server name '#{name}' — use only letters, numbers, hyphens, and underscores"
    end

    # Iterates servers matching a given transport type, yielding each
    # for transport-specific parsing. Servers referencing missing
    # credentials are skipped with a warning — one bad server config
    # must not prevent others from loading.
    #
    # @param transport [String] transport type to filter by ("http", "stdio")
    # @yield [name, settings] block that returns a parsed server hash or nil
    # @return [Array<Hash>] parsed server configs
    def servers_by_transport(transport)
      servers = load_config["servers"] || {}

      servers.filter_map do |name, settings|
        next unless settings["transport"] == transport

        yield(name, settings)
      rescue KeyError => error
        warn_and_skip("server '#{name}' references missing credential #{error.message}")
        nil
      end
    end

    # Logs a warning and collects it for the caller to surface.
    def warn_and_skip(detail)
      message = "MCP: #{detail} — skipping"
      @logger&.warn(message)
      @warnings << message
    end

    # Replaces +${credential:key_name}+ placeholders with values from
    # Rails encrypted credentials via {Mcp::Secrets}.
    #
    # @param value [String] string potentially containing placeholders
    # @return [String] interpolated string
    # @raise [KeyError] if a referenced credential is not stored
    def interpolate_credentials(value)
      Anima.boot_rails!
      require_relative "secrets"

      value.gsub(CREDENTIAL_PATTERN) do
        key = ::Regexp.last_match(1)
        Secrets.get(key) || raise(KeyError, key)
      end
    end

    # Interpolates credentials in all values of a string hash.
    #
    # @param hash [Hash<String, String>] key-value pairs with potential placeholders
    # @return [Hash<String, String>] hash with interpolated values
    def interpolate_hash_values(hash)
      hash.transform_values { |value| interpolate_credentials(value) }
    end
  end
end
