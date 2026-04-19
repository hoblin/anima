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

      # ─── Agent Identity ─────────────────────────────────────────────

      # The agent's display name. Separates engine identity ("Anima") from
      # agent identity — any agent running on Anima can name itself.
      # @return [String]
      def agent_name = get("agent", "name")

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

      # Maximum character length for the Think tool's thoughts parameter.
      # Sub-agents receive half this budget (their tasks are less complex).
      # @return [Integer]
      def thinking_budget = get("llm", "thinking_budget")

      # Model for sub-agent sessions. Sonnet is cost-effective for focused tasks.
      # @return [String] Anthropic model identifier
      def subagent_model = get("llm", "subagent_model")

      # Context window budget for sub-agent sessions.
      # Smaller than main to keep sub-agents out of the "dumb zone".
      # @return [Integer]
      def subagent_token_budget = get("llm", "subagent_token_budget")

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

      # Per-tool-call timeout. Used as the default deadline for orphan detection
      # and as the default value for the tool's `timeout` input parameter.
      # @return [Integer] seconds
      def tool_timeout = get("timeouts", "tool")

      # Polling interval for user interrupt checks during long-running commands.
      # Enforces a 0.5s floor to prevent busy-polling from misconfiguration.
      # @return [Numeric] seconds (minimum 0.5)
      def interrupt_check_interval
        [get("timeouts", "interrupt_check"), 0.5].max
      end

      # ─── Shell ──────────────────────────────────────────────────────

      # Maximum bytes of command output before truncation.
      # @return [Integer]
      def max_output_bytes = get("shell", "max_output_bytes")

      # ─── Tools ──────────────────────────────────────────────────────

      # Maximum file size for read/edit operations (bytes).
      # @return [Integer]
      def max_file_size = get("tools", "max_file_size")

      # Maximum lines returned by the read_file tool.
      # @return [Integer]
      def max_read_lines = get("tools", "max_read_lines")

      # Maximum bytes returned by the read_file tool.
      # @return [Integer]
      def max_read_bytes = get("tools", "max_read_bytes")

      # Maximum bytes from web GET responses.
      # @return [Integer]
      def max_web_response_bytes = get("tools", "max_web_response_bytes")

      # Minimum characters of extracted web content before flagging as possibly incomplete.
      # @return [Integer]
      def min_web_content_chars = get("tools", "min_web_content_chars")

      # Maximum characters of tool output before head+tail truncation.
      # Full output saved to a temp file for paginated reading.
      # @return [Integer]
      def max_tool_response_chars = get("tools", "max_tool_response_chars")

      # Maximum characters of sub-agent result before head+tail truncation.
      # Higher than tool threshold because sub-agent output is already curated.
      # @return [Integer]
      def max_subagent_response_chars = get("tools", "max_subagent_response_chars")

      # ─── Session ────────────────────────────────────────────────────

      # View mode applied to new sessions: "basic", "verbose", or "debug".
      # Changing this setting only affects sessions created afterwards.
      # @return [String]
      # @raise [MissingSettingError] if the value is not a valid view mode
      def default_view_mode
        value = get("session", "default_view_mode")
        unless Session::VIEW_MODES.include?(value)
          raise MissingSettingError,
            "[session] default_view_mode must be one of: #{Session::VIEW_MODES.join(", ")} (got #{value.inspect})"
        end
        value
      end

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

      # ─── Melete ─────────────────────────────────────────

      # Maximum tokens per Melete response.
      # @return [Integer]
      def melete_max_tokens = get("melete", "max_tokens")

      # Number of recent messages to include in Melete's context window.
      # @return [Integer]
      def melete_message_window = get("melete", "message_window")

      # ─── Mneme (Memory Department) ────────────────────────────────

      # Maximum tokens per Mneme LLM response.
      # @return [Integer]
      def mneme_max_tokens = get("mneme", "max_tokens")

      # Fraction of the main token budget for Mneme's eviction zone.
      # @return [Float]
      def eviction_fraction = get("mneme", "eviction_fraction")

      # Fraction of the main viewport token budget reserved for L1 snapshots.
      # @return [Float]
      def mneme_l1_budget_fraction = get("mneme", "l1_budget_fraction")

      # Fraction of the main viewport token budget reserved for L2 snapshots.
      # @return [Float]
      def mneme_l2_budget_fraction = get("mneme", "l2_budget_fraction")

      # Number of uncovered L1 snapshots that triggers L2 compression.
      # @return [Integer]
      def mneme_l2_snapshot_threshold = get("mneme", "l2_snapshot_threshold")

      # Fraction of the main viewport token budget reserved for pinned messages.
      # Pinned messages appear between snapshots and the sliding window.
      # @return [Float]
      def mneme_pinned_budget_fraction = get("mneme", "pinned_budget_fraction")

      # ─── Recall (Associative Memory) ────────────────────────────

      # Maximum search results returned per FTS5 query.
      # @return [Integer]
      def recall_max_results = get("recall", "max_results")

      # Fraction of the main viewport token budget reserved for recalled memories.
      # @return [Float]
      def recall_budget_fraction = get("recall", "budget_fraction")

      # Maximum tokens per individual recall snippet.
      # @return [Integer]
      def recall_max_snippet_tokens = get("recall", "max_snippet_tokens")

      # Recency decay factor for search ranking (0.0 = pure relevance).
      # @return [Float]
      def recall_recency_decay = get("recall", "recency_decay")

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
            "[#{section}] #{key} is not set in #{config_path}. Run `anima update` to add missing settings."
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
