# frozen_string_literal: true

require "thor"

module Anima
  class CLI < Thor
    class Mcp < Thor
      # CLI commands for managing MCP secrets stored in Rails encrypted
      # credentials. Secrets are referenced in mcp.toml via
      # +${credential:key_name}+ syntax.
      #
      # @example Store a secret
      #   anima mcp secrets set linear_api_key=sk-xxx
      #
      # @example List stored secret names
      #   anima mcp secrets list
      #
      # @example Remove a secret
      #   anima mcp secrets remove linear_api_key
      class Secrets < Thor
        def self.exit_on_failure?
          true
        end

        desc "set KEY=VALUE", "Store an MCP secret in encrypted credentials"
        def set(pair)
          key, value = pair.split("=", 2)
          unless value
            say "Error: expected KEY=VALUE format, got '#{pair}'", :red
            exit 1
          end

          require_mcp_secrets.set(key, value)
          say "Stored secret '#{key}'.", :green
        rescue ArgumentError => argument_error
          say "Error: #{argument_error.message}", :red
          exit 1
        end

        desc "list", "List stored MCP secret names (not values)"
        def list
          keys = require_mcp_secrets.list

          if keys.empty?
            say "No MCP secrets stored.", :yellow
            say "Add one with: anima mcp secrets set KEY=VALUE"
            return
          end

          keys.each { |key| say "  #{key}" }
        end

        desc "remove KEY", "Remove an MCP secret from encrypted credentials"
        def remove(key)
          secrets = require_mcp_secrets
          unless secrets.list.include?(key)
            say "Error: secret '#{key}' not found", :red
            exit 1
          end

          secrets.remove(key)
          say "Removed secret '#{key}'.", :green
        end

        private

        def require_mcp_secrets
          Anima.boot_rails!
          require_relative "../../../mcp/secrets"
          require_relative "../../../credential_store"
          ::Mcp::Secrets
        end
      end
    end
  end
end
