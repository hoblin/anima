# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "pathname"

module Anima
  class Installer
    DIRECTORIES = %w[
      agents
      skills
      db
      config/credentials
      log
      tmp
      tmp/pids
      tmp/cache
    ].freeze

    ANIMA_HOME = Pathname.new(File.expand_path("~/.anima")).freeze
    TEMPLATE_DIR = File.expand_path("../../templates", __dir__).freeze

    attr_reader :anima_home

    def initialize(anima_home: ANIMA_HOME)
      @anima_home = anima_home
    end

    def run
      say "Installing Anima to #{anima_home}..."
      create_directories
      create_soul_file
      create_settings_config
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

    # Copies the soul template to ~/.anima/soul.md — the agent's
    # self-authored identity file. Skips if the file already exists
    # so agent-written content is never overwritten.
    def create_soul_file
      soul_path = anima_home.join("soul.md")
      return if soul_path.exist?

      template = File.join(TEMPLATE_DIR, "soul.md")
      soul_path.write(File.read(template))
      say "  created #{soul_path}"
    end

    def create_settings_config
      config_path = anima_home.join("config.toml")
      return if config_path.exist?

      template = File.read(File.join(TEMPLATE_DIR, "config.toml"))
      config_path.write(template.gsub("{{ANIMA_HOME}}") { anima_home.to_s })
      say "  created #{config_path}"
    end

    def create_mcp_config
      config_path = anima_home.join("mcp.toml")
      return if config_path.exist?

      config_path.write(<<~TOML)
        # MCP server configuration
        # Declare MCP servers here. Anima connects on startup and
        # registers their tools alongside built-in ones.
        #
        # HTTP transport:
        # [servers.example]
        # transport = "http"
        # url = "http://localhost:3000/mcp/v2"
        # headers = { Authorization = "Bearer ${API_KEY}" }
        #
        # Stdio transport:
        # [servers.example]
        # transport = "stdio"
        # command = "my-mcp-server"
        # args = ["--verbose"]
        # env = { API_KEY = "${API_KEY}" }
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

        content_str = content_path.to_s
        key_str = key_path.to_s

        key = ActiveSupport::EncryptedFile.generate_key
        key_path.write(key)
        File.chmod(0o600, key_str)

        config = ActiveSupport::EncryptedConfiguration.new(
          config_path: content_str,
          key_path: key_str,
          env_key: "RAILS_MASTER_KEY",
          raise_if_missing_key: true
        )

        config.write("secret_key_base: #{SecureRandom.hex(64)}\n")
        File.chmod(0o600, content_str)
        say "  created credentials for #{env}"
      end
    end

    def create_systemd_service
      service_dir = Pathname.new(File.expand_path("~/.config/systemd/user"))
      service_path = service_dir.join("anima.service")
      FileUtils.mkdir_p(service_dir)

      anima_bin = File.join(Gem.bindir, "anima")
      unit_content = <<~UNIT
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

      already_exists = service_path.exist?
      if already_exists && service_path.read == unit_content
        say "  anima.service unchanged"
      else
        service_path.write(unit_content)
        say "  #{already_exists ? "updated" : "created"} #{service_path}"
      end

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
