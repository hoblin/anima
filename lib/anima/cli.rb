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

    desc "update", "Upgrade gem, migrate config, and restart service"
    option :migrate_only, type: :boolean, default: false, desc: "Skip gem upgrade, only migrate config"
    def update
      require_relative "spinner"

      unless options[:migrate_only]
        success = Spinner.run("Upgrading anima-core gem...") do
          system("gem", "update", "anima-core", out: File::NULL, err: File::NULL)
        end
        unless success
          say "Run manually for details: gem update anima-core", :red
          exit 1
        end

        # Re-exec with the updated gem so migration uses the new template.
        exec(File.join(Gem.bindir, "anima"), "update", "--migrate-only")
      end

      require_relative "config_migrator"

      result = Spinner.run("Migrating brain configuration...") do
        Anima::ConfigMigrator.new.run
      end
      if result.status == :not_found
        say "Config file not found. Run 'anima install' first.", :red
        exit 1
      end
      report_migration("Config", result)

      tui_config_path = File.join(Anima::ConfigMigrator::ANIMA_HOME, "tui.toml")
      tui_template = File.expand_path("../../templates/tui.toml", __dir__)
      unless File.exist?(tui_config_path)
        File.write(tui_config_path, File.read(tui_template))
        say "  created #{tui_config_path} (new in this version)"
      end
      tui_result = Spinner.run("Migrating TUI configuration...") do
        Anima::ConfigMigrator.new(
          config_path: tui_config_path,
          template_path: tui_template
        ).run
      end
      report_migration("TUI config", tui_result)

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
    option :host, desc: "Brain server address (default: from tui.toml or #{DEFAULT_HOST})"
    option :debug, type: :boolean, default: false, desc: "Enable performance logging"
    def tui
      require "ratatui_ruby"
      require_relative "../tui/settings"
      require_relative "../tui/app"

      host = options[:host] || TUI::Settings.default_host

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

    # Reports the outcome of a config migration to the user.
    #
    # @param label [String] human-readable config name (e.g. "Config", "TUI config")
    # @param result [Anima::ConfigMigrator::Result] migration outcome
    # @return [void]
    def report_migration(label, result)
      case result.status
      when :not_found
        say "#{label} file not found. Run 'anima install' first.", :red
      when :up_to_date
        say "  #{label} is already up to date."
      when :updated
        result.additions.each do |addition|
          say "  added [#{addition.section}] #{addition.key} = #{addition.value.inspect}"
        end
      end
    end

    # Restarts the systemd user service so updated code takes effect.
    # Without this, the service continues running the old gem version
    # until manually restarted (see #269).
    #
    # @return [void]
    def restart_service_if_active
      return unless system("systemctl", "--user", "is-active", "--quiet", "anima.service")

      success = Spinner.run("Restarting anima service...") do
        system("systemctl", "--user", "restart", "anima.service")
      end
      unless success
        say "  Run manually: systemctl --user restart anima.service", :red
      end
    end
  end
end
