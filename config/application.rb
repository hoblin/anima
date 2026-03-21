# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "active_job/railtie"
require "action_cable/engine"
require "rails/test_unit/railtie"
require "draper"
require "solid_cable"
require "solid_queue"

Bundler.require(*Rails.groups) if ENV.key?("BUNDLE_GEMFILE")

require_relative "../lib/anima"

module Anima
  class Application < Rails::Application
    config.load_defaults 8.1
    config.api_only = true

    config.autoload_lib(ignore: %w[anima])
    config.active_job.queue_adapter = :solid_queue
    config.solid_queue.connects_to = {database: {writing: :queue}}

    config.action_cable.disable_request_forgery_protection = true

    # Use SQL schema format — FTS5 virtual tables can't be expressed in Ruby DSL.
    config.active_record.schema_format = :sql

    anima_home = Pathname.new(File.expand_path("~/.anima"))

    config.paths["log"] = [anima_home.join("log", "#{Rails.env}.log").to_s]
    config.paths["tmp"] = [anima_home.join("tmp").to_s]

    config.credentials.content_path = anima_home.join("config/credentials/#{Rails.env}.yml.enc")
    config.credentials.key_path = anima_home.join("config/credentials/#{Rails.env}.key")
  end
end
