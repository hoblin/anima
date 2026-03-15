# frozen_string_literal: true

require "pathname"
require_relative "anima/version"
require_relative "anima/settings"

module Anima
  class Error < StandardError; end

  def self.gem_root
    @gem_root ||= Pathname.new(File.expand_path("..", __dir__))
  end
end
