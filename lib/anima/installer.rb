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
      create_config_file
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

    def create_config_file
      config_path = anima_home.join("config", "anima.yml")
      return if config_path.exist?

      config_path.write(<<~YAML)
        # Anima configuration
        # See https://github.com/hoblin/anima for documentation
      YAML
      say "  created #{config_path}"
    end

    def create_settings_config
      config_path = anima_home.join("config.toml")
      return if config_path.exist?

      config_path.write(<<~TOML)
        # Anima Configuration
        #
        # Edit settings below to customize Anima's behavior.
        # Changes take effect immediately — no restart needed.

        # ─── LLM ───────────────────────────────────────────────────────

        [llm]

        # Primary model for conversations.
        model = "claude-sonnet-4-20250514"

        # Lightweight model for fast tasks (e.g. session naming).
        fast_model = "claude-haiku-4-5"

        # Maximum tokens per LLM response.
        max_tokens = 8192

        # Maximum consecutive tool execution rounds per request.
        max_tool_rounds = 25

        # Context window budget — tokens reserved for conversation history.
        # Set this based on your model's context window minus system prompt.
        token_budget = 190_000

        # ─── Timeouts (seconds) ─────────────────────────────────────────

        [timeouts]

        # LLM API request timeout.
        api = 30

        # Shell command execution timeout.
        command = 30

        # MCP server response timeout.
        mcp_response = 60

        # Web fetch request timeout.
        web_request = 10

        # ─── Shell ──────────────────────────────────────────────────────

        [shell]

        # Maximum bytes of command output before truncation.
        max_output_bytes = 100_000

        # ─── Tools ──────────────────────────────────────────────────────

        [tools]

        # Maximum file size for read/edit operations (bytes).
        max_file_size = 10_485_760

        # Maximum lines returned by the read tool.
        max_read_lines = 2_000

        # Maximum bytes returned by the read tool.
        max_read_bytes = 50_000

        # Maximum bytes from web GET responses.
        max_web_response_bytes = 100_000

        # ─── Environment ──────────────────────────────────────────────

        [environment]

        # Files to scan for in the working directory (at root and up to project_files_max_depth subdirectories deep).
        project_files = ["CLAUDE.md", "AGENTS.md", "README.md", "CONTRIBUTING.md"]

        # Maximum directory depth for project file scanning.
        project_files_max_depth = 3

        # ─── GitHub ─────────────────────────────────────────────────────

        [github]

        # Repository for agent feature requests (owner/repo format).
        # Falls back to parsing git remote origin when unset.
        repo = "hoblin/anima"

        # Label applied to agent-created feature request issues.
        label = "anima-wants"

        # ─── Paths ─────────────────────────────────────────────────────

        [paths]

        # The agent's self-authored identity file.
        soul = "#{anima_home.join("soul.md")}"

        # ─── Session ────────────────────────────────────────────────────

        [session]

        # Regenerate session name every N messages.
        name_generation_interval = 30

        # ─── Analytical Brain ─────────────────────────────────────────

        [analytical_brain]

        # Maximum tokens per analytical brain response.
        # Must accommodate multiple tool calls (rename + goals + skills + ready).
        max_tokens = 4096

        # Run the analytical brain synchronously before the main agent on user messages.
        # Ensures activated skills are available for the current response.
        blocking_on_user_message = true

        # Run the analytical brain asynchronously after the main agent completes.
        blocking_on_agent_message = false

        # Number of recent events to include in the analytical brain's context window.
        event_window = 20
      TOML
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
