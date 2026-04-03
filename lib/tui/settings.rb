# frozen_string_literal: true

require "toml-rb"

module TUI
  # TUI-specific configuration backed by +~/.anima/tui.toml+ with hot-reload.
  #
  # Mirrors the {Anima::Settings} pattern (mtime-based caching, thread-safe
  # mutex, clear error messages) but has zero Rails dependency — the TUI is
  # a standalone client process.
  #
  # Settings are grouped into sections matching the TOML file structure:
  #
  #   [connection]  — Brain server address and reconnection behavior
  #   [hud]         — Info panel dimensions and scroll speed
  #   [chat]        — Chat pane scroll and viewport tuning
  #   [terminal]    — Watchdog polling and shutdown grace period
  #   [token_dialog] — API token input masking and popup dimensions
  #   [session_picker] — Session list pagination
  #   [flash]       — Notification auto-dismiss and sizing
  #   [input]       — Text input buffer limits
  #   [performance] — Debug logging path
  #
  # @example Reading a setting
  #   TUI::Settings.default_host        #=> "localhost:42134"
  #   TUI::Settings.hud_min_width       #=> 24
  #
  # @example Hot-reload (no restart needed)
  #   TUI::Settings.hud_scroll_step     #=> 1
  #   # user edits ~/.anima/tui.toml: scroll_step = 3
  #   TUI::Settings.hud_scroll_step     #=> 3
  #
  # @see Anima::Installer#create_tui_config creates the config file
  module Settings
    DEFAULT_PATH = File.expand_path("~/.anima/tui.toml")

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

      # ─── Connection ──────────────────────────────────────────────

      # Default brain server address (host:port).
      # CLI --host flag takes precedence over this value.
      # @return [String]
      def default_host = get("connection", "default_host")

      # Seconds to wait for WebSocket thread cleanup on disconnect.
      # @return [Numeric]
      def disconnect_timeout = get("connection", "disconnect_timeout")

      # Seconds between connection status checks during connect/reconnect.
      # @return [Numeric]
      def poll_interval = get("connection", "poll_interval")

      # Seconds before a connection attempt is considered timed out.
      # @return [Numeric]
      def connection_timeout = get("connection", "connection_timeout")

      # Maximum reconnection attempts before giving up.
      # @return [Integer]
      def max_reconnect_attempts = get("connection", "max_reconnect_attempts")

      # Initial delay before first reconnection attempt (seconds).
      # Doubles with each subsequent attempt up to backoff_cap.
      # @return [Numeric]
      def backoff_base = get("connection", "backoff_base")

      # Maximum delay between reconnection attempts (seconds).
      # @return [Numeric]
      def backoff_cap = get("connection", "backoff_cap")

      # Seconds without an Action Cable ping before the connection is
      # considered stale and a reconnect is triggered.
      # @return [Numeric]
      def ping_stale_threshold = get("connection", "ping_stale_threshold")

      # ─── HUD ─────────────────────────────────────────────────────

      # Minimum width (columns) for the HUD info panel.
      # The HUD occupies 1/3 of screen width, clamped to this minimum.
      # @return [Integer]
      def hud_min_width = get("hud", "min_width")

      # Lines scrolled per keyboard arrow event in the HUD.
      # @return [Integer]
      def hud_scroll_step = get("hud", "scroll_step")

      # Lines scrolled per mouse wheel event in the HUD.
      # @return [Integer]
      def hud_mouse_scroll_step = get("hud", "mouse_scroll_step")

      # ─── Chat ────────────────────────────────────────────────────

      # Minimum height (rows) for the text input area.
      # @return [Integer]
      def min_input_height = get("chat", "min_input_height")

      # Lines scrolled per keyboard arrow event in the chat pane.
      # @return [Integer]
      def chat_scroll_step = get("chat", "scroll_step")

      # Lines scrolled per mouse wheel event in the chat pane.
      # @return [Integer]
      def chat_mouse_scroll_step = get("chat", "mouse_scroll_step")

      # Entries rendered before the scroll target for upward scroll margin.
      # @return [Integer]
      def viewport_back_buffer = get("chat", "viewport_back_buffer")

      # Viewports worth of lines to pre-build for smooth scrolling.
      # @return [Integer]
      def viewport_overflow_multiplier = get("chat", "viewport_overflow_multiplier")

      # Entries from the end before including all trailing entries.
      # @return [Integer]
      def viewport_bottom_threshold = get("chat", "viewport_bottom_threshold")

      # ─── Terminal ────────────────────────────────────────────────

      # How often the watchdog checks if the controlling terminal is alive.
      # @return [Numeric] seconds
      def terminal_check_interval = get("terminal", "check_interval")

      # Grace period for watchdog thread to exit before force-killing it.
      # @return [Numeric] seconds
      def watchdog_shutdown_timeout = get("terminal", "shutdown_timeout")

      # ─── Token Dialog ────────────────────────────────────────────

      # Leading characters shown unmasked in the token input.
      # Matches the "sk-ant-oat01-" prefix plus one secret character.
      # @return [Integer]
      def token_mask_visible = get("token_dialog", "mask_visible")

      # Maximum stars shown in the masked portion of the token display.
      # @return [Integer]
      def token_mask_stars = get("token_dialog", "mask_stars")

      # Height (rows) of the token setup popup.
      # @return [Integer]
      def token_popup_height = get("token_dialog", "popup_height")

      # Minimum width (columns) of the token setup popup.
      # @return [Integer]
      def token_popup_min_width = get("token_dialog", "popup_min_width")

      # ─── Session Picker ──────────────────────────────────────────

      # Sessions displayed per page in the session picker overlay.
      # @return [Integer]
      def session_picker_page_size = get("session_picker", "page_size")

      # Maximum sessions fetched from the brain for client-side pagination.
      # @return [Integer]
      def session_picker_fetch_limit = get("session_picker", "fetch_limit")

      # ─── Flash ───────────────────────────────────────────────────

      # Seconds before flash notifications auto-dismiss.
      # @return [Numeric]
      def flash_auto_dismiss_seconds = get("flash", "auto_dismiss_seconds")

      # Flash area occupies at most 1/N of the chat pane height.
      # @return [Integer]
      def flash_max_height_fraction = get("flash", "max_height_fraction")

      # ─── Input ───────────────────────────────────────────────────

      # Maximum character length for the text input buffer.
      # @return [Integer]
      def input_max_length = get("input", "max_length")

      # ─── Theme ──────────────────────────────────────────────────

      # Progress bar width in characters.
      # @return [Integer]
      def progress_bar_width = get("theme", "progress_bar_width")

      # Rate limit percentage at which the bar turns yellow.
      # @return [Integer]
      def rate_limit_warning = get("theme", "rate_limit_warning")

      # Rate limit percentage at which the bar turns red.
      # @return [Integer]
      def rate_limit_critical = get("theme", "rate_limit_critical")

      # Cache hit percentage above which the bar is green.
      # @return [Integer]
      def cache_hit_good = get("theme", "cache_hit_good")

      # Cache hit percentage below which the bar is red.
      # @return [Integer]
      def cache_hit_low = get("theme", "cache_hit_low")

      # 256-color palette code for user message background.
      # @return [Integer]
      def user_message_bg = get("theme", "user_message_bg")

      # 256-color palette code for assistant message background.
      # @return [Integer]
      def assistant_message_bg = get("theme", "assistant_message_bg")

      # Scrollbar thumb (filled) color.
      # @return [String]
      def scrollbar_thumb = get("theme", "scrollbar_thumb")

      # Scrollbar track (empty) color.
      # @return [String]
      def scrollbar_track = get("theme", "scrollbar_track")

      # Border color for focused panels.
      # @return [String]
      def border_focused = get("theme", "border_focused")

      # Border color for normal (unfocused) panels.
      # @return [String]
      def border_normal = get("theme", "border_normal")

      # Input border color when connected to brain.
      # @return [String]
      def border_input_connected = get("theme", "border_input_connected")

      # Input border color when connecting/reconnecting.
      # @return [String]
      def border_input_connecting = get("theme", "border_input_connecting")

      # Input border color when disconnected.
      # @return [String]
      def border_input_disconnected = get("theme", "border_input_disconnected")

      # ─── Performance ─────────────────────────────────────────────

      # File path for TUI performance debug logs.
      # @return [String]
      def performance_log_path = get("performance", "log_path")

      # ─── Message Store ───────────────────────────────────────────

      # Maximum cache history entries for sparkline rendering.
      # Each braille character encodes 2 data points.
      # @return [Integer]
      def max_cache_history = get("message_store", "max_cache_history")

      private

      # Reads a setting from the config file.
      # Raises if the config file is missing or the key is not defined.
      #
      # @param section [String] TOML section name (e.g. "hud")
      # @param key [String] setting key within the section (e.g. "min_width")
      # @return [Object] the configured value
      # @raise [MissingConfigError] when tui.toml does not exist
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
      # @raise [MissingConfigError] when tui.toml does not exist
      def config
        @cache_mutex.synchronize do
          path = config_path
          unless File.exist?(path)
            @config_cache = nil
            @config_mtime = nil
            raise MissingConfigError,
              "TUI config file not found: #{path}. Run `anima install` to create it."
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
