# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = false
  config.consider_all_requests_local = true
  config.active_support.deprecation = :stderr
  config.active_job.queue_adapter = :test
end
