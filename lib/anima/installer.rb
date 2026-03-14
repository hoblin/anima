# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "pathname"

module Anima
  class Installer
    DIRECTORIES = %w[
      agents
      db
      config/credentials
      log
      tmp
      tmp/pids
      tmp/cache
    ].freeze

    ANIMA_HOME = Pathname.new(File.expand_path("~/.anima")).freeze

    attr_reader :anima_home

    def initialize(anima_home: ANIMA_HOME)
      @anima_home = anima_home
    end

    def run
      say "Installing Anima to #{anima_home}..."
      create_directories
      create_config_file
      create_mcp_config
      generate_credentials
      create_systemd_service
      say "Installation complete. Brain is running. Connect with 'anima tui'."
    end

    def create_directories
      DIRECTORIES.each do |dir|
        path = anima_home.join(dir)
        next if path.directory?

        FileUtils.mkdir_p(path)
        say "  created #{path}"
      end
    end

    def create_config_file
      config_path = anima_home.join("config", "anima.yml")
      return if config_path.exist?

      config_path.write(<<~YAML)
        # Anima configuration
        # See https://github.com/hoblin/anima for documentation
      YAML
      say "  created #{config_path}"
    end

    def create_mcp_config
      config_path = anima_home.join("mcp.toml")
      return if config_path.exist?

      config_path.write(<<~TOML)
        # MCP server configuration
        # Declare HTTP MCP servers here. Anima connects on startup and
        # registers their tools alongside built-in ones.
        #
        # [servers.example]
        # transport = "http"
        # url = "http://localhost:3000/mcp/v2"
        # headers = { Authorization = "Bearer ${API_KEY}" }
      TOML
      say "  created #{config_path}"
    end

    def generate_credentials
      require "active_support"
      require "active_support/encrypted_configuration"

      %w[production development test].each do |env|
        content_path = anima_home.join("config", "credentials", "#{env}.yml.enc")
        key_path = anima_home.join("config", "credentials", "#{env}.key")

        next if key_path.exist? && content_path.exist?

        key = ActiveSupport::EncryptedFile.generate_key
        key_path.write(key)
        File.chmod(0o600, key_path.to_s)

        config = ActiveSupport::EncryptedConfiguration.new(
          config_path: content_path.to_s,
          key_path: key_path.to_s,
          env_key: "RAILS_MASTER_KEY",
          raise_if_missing_key: true
        )

        config.write("secret_key_base: #{SecureRandom.hex(64)}\n")
        File.chmod(0o600, content_path.to_s)
        say "  created credentials for #{env}"
      end
    end

    def create_systemd_service
      service_dir = Pathname.new(File.expand_path("~/.config/systemd/user"))
      service_path = service_dir.join("anima.service")

      return if service_path.exist?

      FileUtils.mkdir_p(service_dir)
      anima_bin = File.join(Gem.bindir, "anima")

      service_path.write(<<~UNIT)
        [Unit]
        Description=Anima - Personal AI Agent
        After=network.target

        [Service]
        Type=simple
        ExecStart=#{anima_bin} start -e production
        Restart=on-failure
        RestartSec=5

        [Install]
        WantedBy=default.target
      UNIT

      say "  created #{service_path}"
      system("systemctl", "--user", "daemon-reload", err: File::NULL, out: File::NULL)
      system("systemctl", "--user", "enable", "--now", "anima.service", err: File::NULL, out: File::NULL)
      say "  enabled and started anima.service"
    end

    private

    def say(message)
      $stdout.puts message
    end
  end
end
