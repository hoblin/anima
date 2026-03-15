# frozen_string_literal: true

# Low-level read/write operations on Rails encrypted credentials.
# Wraps the merge-and-write pattern used by {SessionChannel#write_anthropic_token}
# in a reusable helper. All namespacing (e.g. +mcp+, +anthropic+) is the
# caller's responsibility — this class operates on raw top-level keys.
#
# @example Writing a nested credential
#   CredentialStore.write("mcp", "linear_api_key" => "sk-xxx")
#
# @example Reading a nested credential
#   CredentialStore.read("mcp", "linear_api_key") #=> "sk-xxx"
class CredentialStore
  class << self
    # Writes one or more key-value pairs under a top-level namespace.
    # Merges into existing credentials, preserving sibling keys.
    #
    # @param namespace [String] top-level YAML key (e.g. "mcp", "anthropic")
    # @param pairs [Hash<String, String>] key-value pairs to store
    # @return [void]
    def write(namespace, pairs)
      existing = load_credentials
      section = existing[namespace] ||= {}
      section.merge!(pairs)
      save_credentials(existing)
    end

    # Reads a single credential value from a namespace.
    #
    # @param namespace [String] top-level YAML key
    # @param key [String] credential key within the namespace
    # @return [String, nil] credential value or nil if not found
    def read(namespace, key)
      Rails.application.credentials.dig(namespace.to_sym, key.to_sym)
    end

    # Lists all keys under a namespace.
    #
    # @param namespace [String] top-level YAML key
    # @return [Array<String>] credential keys (not values)
    def list(namespace)
      section = Rails.application.credentials.dig(namespace.to_sym)
      return [] unless section.is_a?(Hash)

      section.keys.map(&:to_s)
    end

    # Removes a single key from a namespace.
    # No-op if the key does not exist.
    #
    # @param namespace [String] top-level YAML key
    # @param key [String] credential key to remove
    # @return [void]
    def remove(namespace, key)
      existing = load_credentials
      section = existing[namespace]
      return unless section.is_a?(Hash)
      return unless section.key?(key)

      section.delete(key)
      existing.delete(namespace) if section.empty?
      save_credentials(existing)
    end

    private

    # Reads and parses the raw YAML from encrypted credentials.
    # Returns an empty hash when the credentials file does not exist yet.
    #
    # @return [Hash] parsed credentials
    def load_credentials
      creds = Rails.application.credentials
      YAML.safe_load(creds.read) || {}
    rescue ActiveSupport::EncryptedFile::MissingContentError
      {}
    end

    # Writes the full credentials hash back to the encrypted file and
    # invalidates the Rails memoization cache so subsequent reads see
    # fresh data.
    #
    # @param data [Hash] complete credentials hash to persist
    # @return [void]
    def save_credentials(data)
      creds = Rails.application.credentials
      creds.write(data.to_yaml)
      # Rails memoizes the decrypted config in @config. Without clearing it,
      # subsequent credential reads return stale data.
      creds.instance_variable_set(:@config, nil)
    end
  end
end
