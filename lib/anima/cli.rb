# frozen_string_literal: true

require "thor"
require_relative "../anima"
require_relative "cli/mcp"

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

    desc "update", "Upgrade gem and migrate config"
    option :migrate_only, type: :boolean, default: false, desc: "Skip gem upgrade, only migrate config"
    def update
      unless options[:migrate_only]
        say "Upgrading anima-core gem..."
        unless system("gem", "update", "anima-core")
          say "Gem update failed.", :red
          exit 1
        end

        # Re-exec with the updated gem so migration uses the new template.
        exec(File.join(Gem.bindir, "anima"), "update", "--migrate-only")
      end

      say "Migrating configuration..."
      require_relative "config_migrator"
      result = Anima::ConfigMigrator.new.run

      case result.status
      when :not_found
        say "Config file not found. Run 'anima install' first.", :red
        exit 1
      when :up_to_date
        say "Config is already up to date."
      when :updated
        result.additions.each do |addition|
          say "  added [#{addition.section}] #{addition.key} = #{addition.value.inspect}"
        end
        say "Config updated. Changes take effect immediately — no restart needed."
      end

      restart_service_if_active
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
    option :debug, type: :boolean, default: false, desc: "Enable performance logging to log/tui_performance.log"
    def tui
      require "ratatui_ruby"
      require_relative "../tui/app"

      host = options[:host] || DEFAULT_HOST

      say "Connecting to brain at #{host}...", :cyan

      cable_client = TUI::CableClient.new(host: host)
      cable_client.connect

      TUI::App.new(cable_client: cable_client, debug: options[:debug]).run
    end

    desc "version", "Show version"
    map %w[-v --version] => :version
    def version
      require_relative "version"
      say "anima #{Anima::VERSION}"
    end

    desc "mcp SUBCOMMAND", "Manage MCP server configuration"
    subcommand "mcp", Mcp

    private

    # Restarts the systemd user service if it is currently running.
    # After a gem update the service still runs the old code until restarted.
    def restart_service_if_active
      return unless system("systemctl", "--user", "is-active", "--quiet", "anima.service")

      say "Restarting anima service..."
      if system("systemctl", "--user", "restart", "anima.service")
        say "Service restarted.", :green
      else
        say "Service restart failed. Run: systemctl --user restart anima.service", :red
      end
    end
  end
end
