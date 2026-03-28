# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = false
  config.consider_all_requests_local = true
  config.active_support.deprecation = :stderr
  config.active_job.queue_adapter = :test

  config.active_record.encryption.primary_key = "test-primary-key-for-ar-encryption"
  config.active_record.encryption.deterministic_key = "test-deterministic-key-for-ar-encryption"
  config.active_record.encryption.key_derivation_salt = "test-key-derivation-salt-for-ar-encryption"
end
