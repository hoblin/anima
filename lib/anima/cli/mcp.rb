# frozen_string_literal: true

require "thor"
require_relative "mcp/secrets"

module Anima
  class CLI < Thor
    # CLI commands for managing MCP server configuration in
    # +~/.anima/mcp.toml+. Mirrors the UX of +claude mcp+ commands.
    class Mcp < Thor
      def self.exit_on_failure?
        true
      end

      desc "secrets SUBCOMMAND", "Manage MCP secrets in encrypted credentials"
      subcommand "secrets", Secrets

      desc "list", "List configured MCP servers with health status"
      def list
        config = build_config
        raw_servers = config.all_servers

        if raw_servers.empty?
          say "No MCP servers configured.", :yellow
          say "Add one with: anima mcp add <name> <url>"
          return
        end

        interpolated = interpolated_lookup(config)
        raw_servers.each { |server| display_server(server, interpolated[server["name"]]) }
        config.warnings.each { |warning| say "  warning: #{warning}", :yellow }
      end

      desc "add NAME URL_OR_COMMAND", "Add an MCP server"
      long_desc <<~DESC
        Add an MCP server to ~/.anima/mcp.toml.

        HTTP server:   anima mcp add <name> <url>
        Stdio server:  anima mcp add <name> -- <command> [args...]

        Use -e KEY=VALUE to set environment variables (stdio servers).
        Use -H "Header: Value" to set HTTP headers (HTTP servers).
        Use -s KEY=VALUE to store a secret in encrypted credentials.
      DESC
      option :env, aliases: "-e", type: :string, repeatable: true, banner: "KEY=VALUE",
        desc: "Environment variables (repeatable)"
      option :header, aliases: "-H", type: :string, repeatable: true, banner: "Header: Value",
        desc: "HTTP headers (repeatable)"
      option :secret, aliases: "-s", type: :string, repeatable: true, banner: "KEY=VALUE",
        desc: "Store secret in encrypted credentials (repeatable)"
      def add(name, *rest)
        if rest.empty?
          say "Error: missing server URL or command.", :red
          say ""
          say "Usage:"
          say "  anima mcp add <name> <url>                  # HTTP server"
          say "  anima mcp add <name> -- <command> [args...]  # stdio server"
          abort_command
        end

        store_secrets(options[:secret])
        settings = build_settings(rest)
        build_config.add_server(name, settings)
        say "Added #{settings["transport"]} server '#{name}' (#{settings_target(settings)}).", :green
      rescue ArgumentError => argument_error
        say "Error: #{argument_error.message}", :red
        abort_command
      end

      desc "remove NAME", "Remove an MCP server"
      def remove(name)
        build_config.remove_server(name)
        say "Removed server '#{name}'.", :green
      rescue ArgumentError => argument_error
        say "Error: #{argument_error.message}", :red
        abort_command
      end

      private

      def abort_command
        exit 1
      end

      def build_config
        require_relative "../../mcp/config"
        ::Mcp::Config.new
      end

      # Stores secrets from -s KEY=VALUE flags in encrypted credentials.
      def store_secrets(secret_strings)
        return unless secret_strings&.any?

        pairs = parse_key_values(secret_strings)
        require_relative "../../mcp/secrets"
        require_relative "../../credential_store"
        pairs.each { |key, value| ::Mcp::Secrets.set(key, value) }
      end

      # Builds interpolated server lookup keyed by name for health checks.
      def interpolated_lookup(config)
        lookup = {}
        populate_lookup(lookup, config.http_servers, "http")
        populate_lookup(lookup, config.stdio_servers, "stdio")
        lookup
      end

      def populate_lookup(lookup, servers, transport)
        servers.each { |server| lookup[server[:name]] = server.merge(transport: transport) }
      end

      # Detects transport from arguments:
      # - First arg starts with http(s):// → HTTP server
      # - Otherwise → stdio server (command + args)
      def build_settings(args)
        first_arg = args.first
        if first_arg.match?(%r{\Ahttps?://})
          build_http_settings(first_arg)
        else
          build_stdio_settings(args)
        end
      end

      def build_http_settings(url)
        settings = {"transport" => "http", "url" => url}
        headers = options[:header]
        settings["headers"] = parse_headers(headers) if headers&.any?
        settings
      end

      def build_stdio_settings(args)
        command, *remaining_args = args
        settings = {"transport" => "stdio", "command" => command}
        settings["args"] = remaining_args if remaining_args.any?
        env_vars = options[:env]
        settings["env"] = parse_key_values(env_vars) if env_vars&.any?
        settings
      end

      def settings_target(settings)
        if settings["transport"] == "http"
          settings["url"]
        else
          [settings["command"], *settings["args"]].join(" ")
        end
      end

      def parse_headers(header_strings)
        header_strings.to_h do |header|
          key, value = header.split(": ", 2)
          raise ArgumentError, "invalid header format '#{header}' — expected 'Name: Value'" unless value

          [key, value]
        end
      end

      def parse_key_values(kv_strings)
        kv_strings.to_h do |kv|
          key, value = kv.split("=", 2)
          raise ArgumentError, "invalid env var format '#{kv}' — expected KEY=VALUE" unless value

          [key, value]
        end
      end

      def display_server(raw, interpolated)
        name = raw["name"]
        transport = raw["transport"]
        detail = server_detail(raw, transport)
        status = interpolated ? check_health(interpolated) : set_color("config error", :red)

        say "  #{name}: #{detail} (#{transport}) — #{status}"
      end

      def server_detail(raw, transport)
        case transport
        when "http" then raw["url"]
        when "stdio" then [raw["command"], *raw["args"]].compact.join(" ")
        else "unknown transport '#{transport}'"
        end
      end

      def check_health(server)
        require_relative "../../mcp/health_check"
        result = ::Mcp::HealthCheck.call(server)

        case result[:status]
        when :connected
          set_color("connected (#{result[:tools]} tools)", :green)
        when :failed
          set_color("failed: #{result[:error]}", :red)
        end
      end
    end
  end
end
