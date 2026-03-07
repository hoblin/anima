# frozen_string_literal: true

require_relative "anima/version"

module Anima
  class Error < StandardError; end

  def self.gem_root
    @gem_root ||= Pathname.new(File.expand_path("..", __dir__))
  end
end
