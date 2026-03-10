# frozen_string_literal: true

require_relative "config/application"
Rails.application.load_tasks

begin
  require "bundler/gem_tasks"
rescue LoadError
  # bundler not available in gem install context
end

begin
  require "rspec/core/rake_task"
  RSpec::Core::RakeTask.new(:spec)
rescue LoadError
  # rspec not available in gem install context
end

begin
  require "standard/rake"
rescue LoadError
  # standard not available in gem install context
end

task default: %i[spec standard] if Rake::Task.task_defined?(:spec) && Rake::Task.task_defined?(:standard)
