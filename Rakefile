# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

require "standard/rake"

require_relative "config/application"
Rails.application.load_tasks

task default: %i[spec standard]
