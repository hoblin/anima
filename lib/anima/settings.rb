# frozen_string_literal: true

require "toml-rb"

module Anima
  # User-facing configuration backed by +~/.anima/config.toml+ with hot-reload.
  #
  # Reads the TOML config file on each access, re-parsing only when the file's
  # mtime has changed. The config file is created by the installer with all
  # values set — it is the single source of truth for all settings.
  #
  # Settings are grouped into sections that mirror the TOML file structure:
  #
  #   [llm]       — Model selection and response limits
  #   [timeouts]  — Network and execution timeouts (seconds)
  #   [shell]     — Shell command output limits
  #   [tools]     — File and web tool limits
  #   [session]   — Conversation behavior
  #
  # @example Reading a setting
  #   Anima::Settings.model          #=> "claude-sonnet-4-20250514"
  #   Anima::Settings.api_timeout    #=> 30
  #
  # @example Hot-reload (no restart needed)
  #   Anima::Settings.model  #=> "claude-sonnet-4-20250514"
  #   # user edits ~/.anima/config.toml: model = "claude-haiku-4-5"
  #   Anima::Settings.model  #=> "claude-haiku-4-5"
  #
  # @see Anima::Installer#create_settings_config creates the config file
  module Settings
    DEFAULT_PATH = File.expand_path("~/.anima/config.toml")

    class MissingConfigError < StandardError; end
    class MissingSettingError < StandardError; end

    @config_path = nil
    @config_cache = nil
    @config_mtime = nil
    @cache_mutex = Mutex.new

    class << self
      # Override config file path (for testing).
      # Resets the cache so the next access reads from the new location.
      #
      # @param path [String, nil] custom path, or +nil+ to restore default
      def config_path=(path)
        @config_path = path
        @config_cache = nil
        @config_mtime = nil
      end

      # @return [String] active config file path
      def config_path
        @config_path || DEFAULT_PATH
      end

      # Resets to default path and clears cached config.
      # Useful in test teardown.
      def reset!
        self.config_path = nil
      end

      # ─── LLM ───────────────────────────────────────────────────────

      # Primary model for conversations.
      # @return [String] Anthropic model identifier
      def model = get("llm", "model")

      # Lightweight model for fast tasks (e.g. session naming).
      # @return [String] Anthropic model identifier
      def fast_model = get("llm", "fast_model")

      # Maximum tokens per LLM response.
      # @return [Integer]
      def max_tokens = get("llm", "max_tokens")

      # Maximum consecutive tool execution rounds per LLM message.
      # Prevents runaway tool loops.
      # @return [Integer]
      def max_tool_rounds = get("llm", "max_tool_rounds")

      # Context window budget — tokens reserved for conversation history.
      # Set this based on your model's context window minus system prompt.
      # @return [Integer]
      def token_budget = get("llm", "token_budget")

      # ─── Timeouts (seconds) ────────────────────────────────────────

      # LLM API request timeout.
      # @return [Integer] seconds
      def api_timeout = get("timeouts", "api")

      # Shell command execution timeout.
      # @return [Integer] seconds
      def command_timeout = get("timeouts", "command")

      # MCP server response timeout.
      # @return [Integer] seconds
      def mcp_response_timeout = get("timeouts", "mcp_response")

      # Web fetch request timeout.
      # @return [Integer] seconds
      def web_request_timeout = get("timeouts", "web_request")

      # ─── Shell ──────────────────────────────────────────────────────

      # Maximum bytes of command output before truncation.
      # @return [Integer]
      def max_output_bytes = get("shell", "max_output_bytes")

      # ─── Tools ──────────────────────────────────────────────────────

      # Maximum file size for read/edit operations (bytes).
      # @return [Integer]
      def max_file_size = get("tools", "max_file_size")

      # Maximum lines returned by the read tool.
      # @return [Integer]
      def max_read_lines = get("tools", "max_read_lines")

      # Maximum bytes returned by the read tool.
      # @return [Integer]
      def max_read_bytes = get("tools", "max_read_bytes")

      # Maximum bytes from web GET responses.
      # @return [Integer]
      def max_web_response_bytes = get("tools", "max_web_response_bytes")

      # ─── Session ────────────────────────────────────────────────────

      # Regenerate session name every N messages.
      # @return [Integer]
      def name_generation_interval = get("session", "name_generation_interval")

      # ─── Paths ───────────────────────────────────────────────────────

      # Path to the soul file — the agent's self-authored identity.
      # @return [String] absolute path
      def soul_path = get("paths", "soul")

      # ─── Environment ──────────────────────────────────────────────

      # Filenames to scan for in the working directory.
      # @return [Array<String>]
      def project_files_whitelist = get("environment", "project_files")

      # Maximum directory depth for project file scanning.
      # @return [Integer]
      def project_files_max_depth = get("environment", "project_files_max_depth")

      # ─── GitHub ─────────────────────────────────────────────────────

      # Repository for feature requests (+owner/repo+ format).
      # Falls back to parsing git remote origin when unset.
      # @return [String]
      def github_repo = get("github", "repo")

      # Label applied to agent-created feature request issues.
      # @return [String]
      def github_label = get("github", "label")

      # ─── Analytical Brain ─────────────────────────────────────────

      # Maximum tokens per analytical brain response.
      # @return [Integer]
      def analytical_brain_max_tokens = get("analytical_brain", "max_tokens")

      # Run the analytical brain synchronously before the main agent on user messages.
      # @return [Boolean]
      def analytical_brain_blocking_on_user_message = get("analytical_brain", "blocking_on_user_message")

      # Run the analytical brain asynchronously after the main agent completes.
      # @return [Boolean]
      def analytical_brain_blocking_on_agent_message = get("analytical_brain", "blocking_on_agent_message")

      # Number of recent events to include in the analytical brain's context window.
      # @return [Integer]
      def analytical_brain_event_window = get("analytical_brain", "event_window")

      private

      # Reads a setting from the config file.
      # Raises if the config file is missing or the key is not defined.
      #
      # @param section [String] TOML section name (e.g. "llm")
      # @param key [String] setting key within the section (e.g. "model")
      # @return [Object] the configured value
      # @raise [MissingConfigError] when config.toml does not exist
      # @raise [MissingSettingError] when the requested key is not in config
      def get(section, key)
        value = config.dig(section, key)
        if value.nil?
          raise MissingSettingError,
            "[#{section}] #{key} is not set in #{config_path}. Run `anima install` to create the config file."
        end
        value
      end

      # Loads the TOML config with mtime-based caching.
      # Re-parses only when the file has been modified since the last read.
      # Thread-safe via mutex — concurrent callers share the same cache.
      #
      # @return [Hash] parsed config
      # @raise [MissingConfigError] when config.toml does not exist
      def config
        @cache_mutex.synchronize do
          path = config_path
          unless File.exist?(path)
            @config_cache = nil
            @config_mtime = nil
            raise MissingConfigError,
              "Config file not found: #{path}. Run `anima install` to create it."
          end

          current_mtime = File.mtime(path)
          if current_mtime != @config_mtime
            @config_mtime = current_mtime
            @config_cache = TomlRB.load_file(path)
          end

          @config_cache
        end
      end
    end
  end
end
