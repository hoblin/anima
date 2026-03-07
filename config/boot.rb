# frozen_string_literal: true

gemfile = File.expand_path("../Gemfile", __dir__)

if File.exist?(gemfile)
  ENV["BUNDLE_GEMFILE"] ||= gemfile
  require "bundler/setup"
end
