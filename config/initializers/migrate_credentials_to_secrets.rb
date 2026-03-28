# frozen_string_literal: true

# One-time migration: copies secrets from Rails encrypted credentials to
# the Secret model (Active Record Encryption). Runs on first boot after
# upgrade. Idempotent — skips namespaces that already have entries.
#
# After migration, Rails credentials retain only +secret_key_base+.
# API tokens and MCP secrets live in the +secrets+ table.
Rails.application.config.after_initialize do
  next if Rails.env.test?
  next unless Secret.table_exists?
  next if Secret.any?

  creds = begin
    raw = Rails.application.credentials.read
    YAML.safe_load(raw) || {}
  rescue ActiveSupport::EncryptedFile::MissingContentError
    {}
  end

  migrated = 0
  creds.each do |namespace, section|
    next if namespace == "secret_key_base"
    next unless section.is_a?(Hash)

    section.each do |key, value|
      Secret.write(namespace, key.to_s => value.to_s)
      migrated += 1
    end
  end

  Rails.logger.info "Migrated #{migrated} credentials to encrypted secrets table" if migrated > 0
end
