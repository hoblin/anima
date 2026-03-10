# frozen_string_literal: true

require "thor"

module Anima
  class CLI < Thor
    VALID_ENVIRONMENTS = %w[development test production].freeze
    DEFAULT_HOST = "localhost:42134"

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
      system(gem_root.join("bin/rails").to_s, "db:prepare") || abort("db:prepare failed")
      exec("foreman", "start", "-f", gem_root.join("Procfile").to_s)
    end

    desc "tui", "Launch the Anima terminal interface"
    option :host, desc: "Brain server address (default: #{DEFAULT_HOST})"
    def tui
      require "ratatui_ruby"
      require "net/http"
      require "json"
      require_relative "../tui/app"

      host = options[:host] || DEFAULT_HOST

      say "Connecting to brain at #{host}...", :cyan
      session_id = fetch_current_session_with_retry(host)
      say "Session ##{session_id} — starting TUI", :cyan

      cable_client = TUI::CableClient.new(host: host, session_id: session_id)
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

    MAX_SESSION_FETCH_ATTEMPTS = 10
    SESSION_FETCH_DELAY = 2 # seconds between retries

    # Fetches the current session ID from the brain's REST API.
    # Retries up to {MAX_SESSION_FETCH_ATTEMPTS} times if the brain is not running.
    #
    # @param host [String] brain server address
    # @return [Integer] session ID
    def fetch_current_session_with_retry(host)
      attempts = 0
      begin
        fetch_current_session(host)
      rescue Errno::ECONNREFUSED, Net::ReadTimeout, Net::OpenTimeout, SocketError => error
        attempts += 1
        if attempts >= MAX_SESSION_FETCH_ATTEMPTS
          say "Cannot connect to brain after #{MAX_SESSION_FETCH_ATTEMPTS} attempts", :red
          exit 1
        end
        say "Brain not available (#{error.class.name.split("::").last}). " \
            "Retrying #{attempts}/#{MAX_SESSION_FETCH_ATTEMPTS}... (Ctrl+C to cancel)", :yellow
        sleep SESSION_FETCH_DELAY
        retry
      end
    end

    # Fetches the current session ID from the brain's REST API.
    # @param host [String] brain server address
    # @return [Integer] session ID
    # @raise [RuntimeError] if the brain returns an error response
    def fetch_current_session(host)
      uri = URI("http://#{host}/api/sessions/current")
      body = Net::HTTP.get(uri)
      JSON.parse(body)["id"]
    end
  end
end
