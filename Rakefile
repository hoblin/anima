# frozen_string_literal: true

require_relative "config/application"
Rails.application.load_tasks

begin
  require "bundler/gem_tasks"
  require "rspec/core/rake_task"
  RSpec::Core::RakeTask.new(:spec)
  require "standard/rake"
  task default: %i[spec standard]
rescue LoadError, RuntimeError
  # Dev dependencies not available in gem install context
end
