# frozen_string_literal: true

# Encrypted key-value storage for runtime secrets (API tokens, credentials).
# Replaces Rails encrypted credentials for secrets that must be readable
# across forked Solid Queue workers without cache-busting hacks.
#
# Secrets are organized by namespace (e.g. +"anthropic"+, +"mcp"+) and key
# (e.g. +"subscription_token"+). Values are encrypted at rest using Active
# Record Encryption — only the +value+ column is encrypted; +namespace+ and
# +key+ are plain text for queryability.
#
# @!attribute namespace
#   @return [String] grouping key (e.g. "anthropic", "mcp")
# @!attribute key
#   @return [String] credential identifier within the namespace
# @!attribute value
#   @return [String] the secret value (encrypted at rest)
class Secret < ApplicationRecord
  encrypts :value

  validates :namespace, presence: true
  validates :key, presence: true
  validates :value, presence: true
  validates :key, uniqueness: {scope: :namespace}

  scope :for_namespace, ->(ns) { where(namespace: ns) }

  # Reads a single secret value.
  #
  # @param namespace [String] top-level grouping key
  # @param key [String] credential key within the namespace
  # @return [String, nil] decrypted value or nil if not found
  def self.read(namespace, key)
    find_by(namespace: namespace, key: key)&.value
  end

  # Writes one or more key-value pairs under a namespace.
  # Uses upsert to insert or update atomically.
  #
  # @param namespace [String] top-level grouping key
  # @param pairs [Hash<String, String>] key-value pairs to store
  # @return [void]
  def self.write(namespace, pairs)
    pairs.each do |secret_key, secret_value|
      record = find_or_initialize_by(namespace: namespace, key: secret_key)
      record.update!(value: secret_value)
    end
  end

  # Lists all keys under a namespace (not values).
  #
  # @param namespace [String] top-level grouping key
  # @return [Array<String>] credential keys
  def self.list(namespace)
    for_namespace(namespace).pluck(:key)
  end

  # Removes a single key from a namespace.
  #
  # @param namespace [String] top-level grouping key
  # @param key [String] credential key to remove
  # @return [void]
  def self.remove(namespace, key)
    find_by(namespace: namespace, key: key)&.destroy!
  end
end
