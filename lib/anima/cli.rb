# frozen_string_literal: true

require "thor"

module Anima
  GEM_ROOT = Pathname.new(File.expand_path("../..", __dir__))

  class CLI < Thor
    def self.exit_on_failure?
      true
    end

    desc "install", "Set up ~/.anima/ with databases, credentials, and systemd service"
    def install
      require_relative "installer"
      Installer.new.run
    end

    desc "start", "Boot Anima (runs pending migrations, then exits)"
    option :environment, aliases: "-e", default: "development", desc: "Rails environment"
    def start
      ENV["RAILS_ENV"] = options[:environment]

      unless File.directory?(File.expand_path("~/.anima"))
        say "Anima is not installed. Run 'anima install' first.", :red
        exit 1
      end

      system("#{GEM_ROOT}/bin/rails", "db:prepare") || abort("db:prepare failed")
      say "Anima booted successfully (#{options[:environment]}).", :green
    end

    desc "version", "Show version"
    map %w[-v --version] => :version
    def version
      require_relative "version"
      say "anima #{Anima::VERSION}"
    end
  end
end
