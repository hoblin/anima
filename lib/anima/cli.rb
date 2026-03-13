# frozen_string_literal: true

require "thor"
require_relative "../anima"

module Anima
  class CLI < Thor
    VALID_ENVIRONMENTS = %w[development test production].freeze
    DEFAULT_PORT = 42134
    DEFAULT_HOST = "localhost:#{DEFAULT_PORT}"

    def self.exit_on_failure?
      true
    end

    desc "install", "Set up ~/.anima/ with databases, credentials, and systemd service"
    def install
      require_relative "installer"
      Installer.new.run
    end

    # Start the Anima brain server (Puma + Solid Queue) via Foreman.
    # Environment precedence: -e flag > RAILS_ENV env var > "development".
    # Requires prior installation (~/.anima must exist).
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
      system(gem_root.join("bin/rails").to_s, "db:prepare", chdir: gem_root.to_s) || abort("db:prepare failed")
      exec("foreman", "start", "-f", gem_root.join("Procfile").to_s, "-p", DEFAULT_PORT.to_s, chdir: gem_root.to_s)
    end

    desc "tui", "Launch the Anima terminal interface"
    option :host, desc: "Brain server address (default: #{DEFAULT_HOST})"
    def tui
      require "ratatui_ruby"
      require_relative "../tui/app"

      host = options[:host] || DEFAULT_HOST

      say "Connecting to brain at #{host}...", :cyan

      cable_client = TUI::CableClient.new(host: host)
      cable_client.connect

      TUI::App.new(cable_client: cable_client).run
    end

    desc "version", "Show version"
    map %w[-v --version] => :version
    def version
      require_relative "version"
      say "anima #{Anima::VERSION}"
    end

    private
  end
end
