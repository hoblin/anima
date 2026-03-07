# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.log_level = :info
  config.active_support.deprecation = :notify
end
