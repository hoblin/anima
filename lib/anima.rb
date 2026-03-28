# frozen_string_literal: true

require "pathname"
require_relative "anima/version"
require_relative "anima/settings"

module Anima
  class Error < StandardError; end

  def self.gem_root
    @gem_root ||= Pathname.new(File.expand_path("..", __dir__))
  end

  # Boots Rails when CLI commands need access to Rails-managed resources
  # like the encrypted secrets table. No-op if Rails is already loaded.
  def self.boot_rails!
    return if defined?(Rails)

    require gem_root.join("config", "environment").to_s
  end
end
