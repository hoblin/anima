# frozen_string_literal: true

require "spec_helper"
require "tui/settings"
require "tmpdir"
require "tempfile"

RSpec.describe TUI::Settings do
  let(:full_config) do
    {
      "connection" => {
        "default_host" => "localhost:42134",
        "disconnect_timeout" => 2,
        "poll_interval" => 0.1,
        "connection_timeout" => 10,
        "max_reconnect_attempts" => 10,
        "backoff_base" => 1.0,
        "backoff_cap" => 30.0,
        "ping_stale_threshold" => 6.0
      },
      "hud" => {
        "min_width" => 24,
        "scroll_step" => 1,
        "mouse_scroll_step" => 2
      },
      "chat" => {
        "min_input_height" => 3,
        "scroll_step" => 1,
        "mouse_scroll_step" => 2,
        "viewport_back_buffer" => 3,
        "viewport_overflow_multiplier" => 2,
        "viewport_bottom_threshold" => 10
      },
      "terminal" => {
        "check_interval" => 0.5,
        "shutdown_timeout" => 1
      },
      "token_dialog" => {
        "mask_visible" => 14,
        "mask_stars" => 4,
        "popup_height" => 14,
        "popup_min_width" => 44
      },
      "session_picker" => {
        "page_size" => 9,
        "fetch_limit" => 50
      },
      "flash" => {
        "auto_dismiss_seconds" => 20.0,
        "max_height_fraction" => 3
      },
      "input" => {
        "max_length" => 10_000
      },
      "message_store" => {
        "max_cache_history" => 200
      },
      "theme" => {
        "progress_bar_width" => 8,
        "rate_limit_warning" => 70,
        "rate_limit_critical" => 90,
        "cache_hit_good" => 70,
        "cache_hit_low" => 30,
        "user_message_bg" => 22,
        "assistant_message_bg" => 17,
        "scrollbar_thumb" => "cyan",
        "scrollbar_track" => "dark_gray",
        "border_focused" => "yellow",
        "border_normal" => "white",
        "border_input_connected" => "green",
        "border_input_connecting" => "yellow",
        "border_input_disconnected" => "dark_gray"
      },
      "performance" => {
        "log_path" => "log/tui_performance.log"
      }
    }
  end

  before { allow(described_class).to receive(:config).and_return(full_config) }

  describe "accessors read from config" do
    it "reads connection settings" do
      expect(described_class.default_host).to eq("localhost:42134")
      expect(described_class.disconnect_timeout).to eq(2)
      expect(described_class.poll_interval).to eq(0.1)
      expect(described_class.connection_timeout).to eq(10)
      expect(described_class.max_reconnect_attempts).to eq(10)
      expect(described_class.backoff_base).to eq(1.0)
      expect(described_class.backoff_cap).to eq(30.0)
      expect(described_class.ping_stale_threshold).to eq(6.0)
    end

    it "reads HUD settings" do
      expect(described_class.hud_min_width).to eq(24)
      expect(described_class.hud_scroll_step).to eq(1)
      expect(described_class.hud_mouse_scroll_step).to eq(2)
    end

    it "reads chat settings" do
      expect(described_class.min_input_height).to eq(3)
      expect(described_class.chat_scroll_step).to eq(1)
      expect(described_class.chat_mouse_scroll_step).to eq(2)
      expect(described_class.viewport_back_buffer).to eq(3)
      expect(described_class.viewport_overflow_multiplier).to eq(2)
      expect(described_class.viewport_bottom_threshold).to eq(10)
    end

    it "reads terminal settings" do
      expect(described_class.terminal_check_interval).to eq(0.5)
      expect(described_class.watchdog_shutdown_timeout).to eq(1)
    end

    it "reads token dialog settings" do
      expect(described_class.token_mask_visible).to eq(14)
      expect(described_class.token_mask_stars).to eq(4)
      expect(described_class.token_popup_height).to eq(14)
      expect(described_class.token_popup_min_width).to eq(44)
    end

    it "reads session picker settings" do
      expect(described_class.session_picker_page_size).to eq(9)
      expect(described_class.session_picker_fetch_limit).to eq(50)
    end

    it "reads flash settings" do
      expect(described_class.flash_auto_dismiss_seconds).to eq(20.0)
      expect(described_class.flash_max_height_fraction).to eq(3)
    end

    it "reads input settings" do
      expect(described_class.input_max_length).to eq(10_000)
    end

    it "reads message store settings" do
      expect(described_class.max_cache_history).to eq(200)
    end

    it "reads theme settings" do
      expect(described_class.progress_bar_width).to eq(8)
      expect(described_class.rate_limit_warning).to eq(70)
      expect(described_class.rate_limit_critical).to eq(90)
      expect(described_class.cache_hit_good).to eq(70)
      expect(described_class.cache_hit_low).to eq(30)
      expect(described_class.user_message_bg).to eq(22)
      expect(described_class.assistant_message_bg).to eq(17)
      expect(described_class.scrollbar_thumb).to eq("cyan")
      expect(described_class.scrollbar_track).to eq("dark_gray")
      expect(described_class.border_focused).to eq("yellow")
      expect(described_class.border_normal).to eq("white")
      expect(described_class.border_input_connected).to eq("green")
      expect(described_class.border_input_connecting).to eq("yellow")
      expect(described_class.border_input_disconnected).to eq("dark_gray")
    end

    it "reads performance settings" do
      expect(described_class.performance_log_path).to eq("log/tui_performance.log")
    end
  end

  describe "missing config file" do
    before do
      allow(described_class).to receive(:config).and_raise(
        TUI::Settings::MissingConfigError, "TUI config file not found: /missing/tui.toml. Run `anima install` to create it."
      )
    end

    it "raises MissingConfigError" do
      expect { described_class.default_host }.to raise_error(
        TUI::Settings::MissingConfigError, /not found/
      )
    end
  end

  describe "missing setting" do
    before do
      allow(described_class).to receive(:config).and_return(
        "connection" => {"default_host" => "localhost:42134"}
      )
    end

    it "raises MissingSettingError for absent key" do
      expect { described_class.hud_min_width }.to raise_error(
        TUI::Settings::MissingSettingError, /\[hud\] min_width is not set/
      )
    end

    it "raises MissingSettingError for absent key in present section" do
      expect { described_class.disconnect_timeout }.to raise_error(
        TUI::Settings::MissingSettingError, /\[connection\] disconnect_timeout is not set/
      )
    end
  end

  describe ".config_path" do
    after { described_class.reset! }

    it "defaults to ~/.anima/tui.toml" do
      expect(described_class.config_path).to eq(File.expand_path("~/.anima/tui.toml"))
    end

    it "can be overridden" do
      described_class.config_path = "/custom/tui.toml"
      expect(described_class.config_path).to eq("/custom/tui.toml")
    end

    it "resets to default via reset!" do
      described_class.config_path = "/custom/tui.toml"
      described_class.reset!
      expect(described_class.config_path).to eq(File.expand_path("~/.anima/tui.toml"))
    end
  end

  describe "hot-reload" do
    let(:config_file) { Tempfile.new(["tui-config", ".toml"]) }

    before do
      allow(described_class).to receive(:config).and_call_original
      config_file.write(<<~TOML)
        [connection]
        default_host = "localhost:42134"
        disconnect_timeout = 2
        poll_interval = 0.1
        connection_timeout = 10
        max_reconnect_attempts = 10
        backoff_base = 1.0
        backoff_cap = 30.0
        ping_stale_threshold = 6.0
        [hud]
        min_width = 24
        scroll_step = 1
        mouse_scroll_step = 2
      TOML
      config_file.flush
      described_class.config_path = config_file.path
    end

    after do
      described_class.reset!
      config_file.close
      config_file.unlink
    end

    it "reads values from a real TOML file" do
      expect(described_class.default_host).to eq("localhost:42134")
      expect(described_class.hud_min_width).to eq(24)
    end

    it "picks up changes when the file is modified" do
      expect(described_class.hud_min_width).to eq(24)

      sleep 0.01
      config_file.reopen(config_file.path, "w")
      config_file.write(<<~TOML)
        [connection]
        default_host = "localhost:42135"
        disconnect_timeout = 2
        poll_interval = 0.1
        connection_timeout = 10
        max_reconnect_attempts = 10
        backoff_base = 1.0
        backoff_cap = 30.0
        ping_stale_threshold = 6.0
        [hud]
        min_width = 30
        scroll_step = 1
        mouse_scroll_step = 2
      TOML
      config_file.flush
      FileUtils.touch(config_file.path, mtime: Time.now + 1)

      expect(described_class.hud_min_width).to eq(30)
      expect(described_class.default_host).to eq("localhost:42135")
    end

    it "does not re-parse TOML when file has not changed" do
      described_class.default_host
      expect(TomlRB).not_to receive(:load_file)
      2.times { described_class.default_host }
    end
  end
end
