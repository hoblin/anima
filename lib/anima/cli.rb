# frozen_string_literal: true

require "thor"

module Anima
  class CLI < Thor
    VALID_ENVIRONMENTS = %w[development test production].freeze

    def self.exit_on_failure?
      true
    end

    desc "install", "Set up ~/.anima/ with databases, credentials, and systemd service"
    def install
      require_relative "installer"
      Installer.new.run
    end

    desc "start", "Start Anima (web + workers)"
    option :environment, aliases: "-e", desc: "Rails environment (default: $RAILS_ENV or development)"
    def start
      env = options[:environment] || ENV.fetch("RAILS_ENV", "development")
      unless VALID_ENVIRONMENTS.include?(env)
        say "Invalid environment: #{env}. Must be one of: #{VALID_ENVIRONMENTS.join(", ")}", :red
        exit 1
      end

      ENV["RAILS_ENV"] = env

      unless File.directory?(File.expand_path("~/.anima"))
        say "Anima is not installed. Run 'anima install' first.", :red
        exit 1
      end

      gem_root = Anima.gem_root
      system(gem_root.join("bin/rails").to_s, "db:prepare") || abort("db:prepare failed")
      exec("foreman", "start", "-f", gem_root.join("Procfile").to_s)
    end

    desc "tui", "Launch the Anima terminal interface"
    def tui
      require "ratatui_ruby"
      ENV["RAILS_ENV"] ||= "development"
      require_relative "../../config/environment"
      ActiveRecord::Tasks::DatabaseTasks.prepare_all
      TUI::App.new.run
    end

    desc "version", "Show version"
    map %w[-v --version] => :version
    def version
      require_relative "version"
      say "anima #{Anima::VERSION}"
    end
  end
end
