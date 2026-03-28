# frozen_string_literal: true

require "securerandom"
require "yaml"
require "fileutils"

module Anima
  # Generates and loads Active Record Encryption keys from a file in
  # +~/.anima/config/encryption.key+. Keys are generated once during
  # installation and reused on every boot.
  #
  # The key file stores three Base64-encoded 32-byte keys:
  # - +primary_key+ — envelope encryption master key
  # - +deterministic_key+ — used for queryable encrypted fields
  # - +key_derivation_salt+ — salt for key derivation
  #
  # @see https://guides.rubyonrails.org/active_record_encryption.html
  module EncryptionKeys
    KEY_FILE = File.expand_path("~/.anima/config/encryption.key")

    class << self
      # Loads existing keys or generates new ones if the key file is missing.
      #
      # @return [Hash{Symbol => String}] +:primary_key+, +:deterministic_key+, +:key_derivation_salt+
      def load_or_generate
        if File.exist?(key_file)
          load_keys
        else
          generate_and_save
        end
      end

      # Generates fresh keys and writes them to the key file with 0600 permissions.
      #
      # @return [Hash{Symbol => String}] the newly generated keys
      def generate_and_save
        keys = %w[primary_key deterministic_key key_derivation_salt]
          .to_h { |name| [name, SecureRandom.base64(32)] }

        FileUtils.mkdir_p(File.dirname(key_file))
        File.write(key_file, YAML.dump(keys))
        File.chmod(0o600, key_file)

        symbolize(keys)
      end

      # Override key file path (for testing).
      # @param path [String, nil] custom path, or +nil+ to restore default
      attr_writer :key_file

      # @return [String] active key file path
      def key_file
        @key_file || KEY_FILE
      end

      private

      def load_keys
        symbolize(YAML.safe_load_file(key_file))
      end

      def symbolize(hash)
        hash.transform_keys(&:to_sym)
      end
    end
  end
end
