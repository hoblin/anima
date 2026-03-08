# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require_relative "../config/environment"
require "rspec/rails"
require "webmock/rspec"

# Ensure test database schema is current (critical for CI where db/schema.rb is gitignored).
ActiveRecord::Tasks::DatabaseTasks.prepare_all

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!
  config.include ActiveJob::TestHelper
end
