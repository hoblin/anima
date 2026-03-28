# frozen_string_literal: true

# Read/write operations for runtime secrets (API tokens, MCP credentials).
# Backed by the {Secret} model with Active Record Encryption — values are
# encrypted at rest and always fresh (no caching, no file-path issues in
# forked Solid Queue workers).
#
# All namespacing (e.g. +mcp+, +anthropic+) is the caller's responsibility.
#
# @example Writing a nested credential
#   CredentialStore.write("mcp", "linear_api_key" => "sk-xxx")
#
# @example Reading a nested credential
#   CredentialStore.read("mcp", "linear_api_key") #=> "sk-xxx"
class CredentialStore
  class << self
    # Writes one or more key-value pairs under a top-level namespace.
    # Upserts: existing keys are updated, new keys are created.
    #
    # @param namespace [String] top-level grouping key (e.g. "mcp", "anthropic")
    # @param pairs [Hash<String, String>] key-value pairs to store
    # @return [void]
    def write(namespace, pairs)
      Secret.write(namespace, pairs)
    end

    # Reads a single credential value from a namespace.
    #
    # @param namespace [String] top-level grouping key
    # @param key [String] credential key within the namespace
    # @return [String, nil] credential value or nil if not found
    def read(namespace, key)
      Secret.read(namespace, key)
    end

    # Lists all keys under a namespace (not values).
    #
    # @param namespace [String] top-level grouping key
    # @return [Array<String>] credential keys
    def list(namespace)
      Secret.list(namespace)
    end

    # Removes a single key from a namespace.
    # No-op if the key does not exist.
    #
    # @param namespace [String] top-level grouping key
    # @param key [String] credential key to remove
    # @return [void]
    def remove(namespace, key)
      Secret.remove(namespace, key)
    end
  end
end
