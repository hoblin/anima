# frozen_string_literal: true

module Mcp
  # CRUD operations for MCP server secrets stored in the encrypted secrets table.
  # Secrets live under the +mcp+ namespace:
  #
  #   Mcp::Secrets.set("linear_api_key", "sk-xxx")
  #   Mcp::Secrets.get("linear_api_key") #=> "sk-xxx"
  #
  # Referenced in mcp.toml via +${credential:key_name}+ syntax, resolved at
  # runtime by {Mcp::Config#interpolate_credentials}.
  #
  # @example Storing a secret
  #   Mcp::Secrets.set("linear_api_key", "sk-xxx")
  #
  # @example Retrieving a secret
  #   Mcp::Secrets.get("linear_api_key") #=> "sk-xxx"
  class Secrets
    NAMESPACE = "mcp"

    # Keys must be interpolatable via ${credential:key_name} in mcp.toml.
    VALID_KEY_PATTERN = /\A\w+\z/

    class << self
      # Stores a secret in encrypted storage.
      #
      # @param key [String] secret identifier (e.g. "linear_api_key")
      # @param value [String] secret value
      # @return [void]
      # @raise [ArgumentError] if key contains characters that cannot be
      #   referenced via +${credential:key_name}+ syntax
      def set(key, value)
        validate_key!(key)
        CredentialStore.write(NAMESPACE, key => value)
      end

      # Retrieves a secret from encrypted storage.
      #
      # @param key [String] secret identifier
      # @return [String, nil] secret value or nil if not found
      def get(key)
        CredentialStore.read(NAMESPACE, key)
      end

      # Lists all stored MCP secret keys (not values).
      #
      # @return [Array<String>] secret names
      def list
        CredentialStore.list(NAMESPACE)
      end

      # Removes a secret from encrypted storage.
      #
      # @param key [String] secret identifier to remove
      # @return [void]
      def remove(key)
        CredentialStore.remove(NAMESPACE, key)
      end

      private

      # @raise [ArgumentError] if key is not interpolatable
      def validate_key!(key)
        return if key.match?(VALID_KEY_PATTERN)

        raise ArgumentError,
          "invalid secret key '#{key}' — use only letters, numbers, and underscores " \
          "(must match ${credential:key_name} syntax)"
      end
    end
  end
end
