# frozen_string_literal: true

require "spec_helper"
require "tui/settings"
require "tmpdir"
require "tempfile"

RSpec.describe TUI::Settings do
  let(:template_path) { File.expand_path("../../../templates/tui.toml", __dir__) }

  before { described_class.config_path = template_path }
  after { described_class.reset! }

  describe "accessors generated from template" do
    it "generates a method for every section_key in the template" do
      TUI::Settings::TEMPLATE.each do |section, keys|
        keys.each_key do |key|
          method_name = :"#{section}_#{key}"
          expect(described_class).to respond_to(method_name), "expected Settings.#{method_name} to exist"
        end
      end
    end

    it "reads connection settings" do
      expect(described_class.connection_default_host).to eq("localhost:42134")
      expect(described_class.connection_disconnect_timeout).to eq(2)
      expect(described_class.connection_poll_interval).to eq(0.1)
      expect(described_class.connection_timeout).to eq(10)
      expect(described_class.connection_max_reconnect_attempts).to eq(10)
      expect(described_class.connection_backoff_base).to eq(1.0)
      expect(described_class.connection_backoff_cap).to eq(30.0)
      expect(described_class.connection_ping_stale_threshold).to eq(6.0)
    end

    it "reads HUD settings" do
      expect(described_class.hud_min_width).to eq(24)
      expect(described_class.hud_scroll_step).to eq(1)
      expect(described_class.hud_mouse_scroll_step).to eq(2)
    end

    it "reads chat settings" do
      expect(described_class.chat_min_input_height).to eq(3)
      expect(described_class.chat_scroll_step).to eq(1)
      expect(described_class.chat_mouse_scroll_step).to eq(2)
      expect(described_class.chat_viewport_back_buffer).to eq(3)
      expect(described_class.chat_viewport_overflow_multiplier).to eq(2)
      expect(described_class.chat_viewport_bottom_threshold).to eq(10)
    end

    it "reads terminal settings" do
      expect(described_class.terminal_check_interval).to eq(0.5)
      expect(described_class.terminal_shutdown_timeout).to eq(1)
    end

    it "reads token dialog settings" do
      expect(described_class.token_dialog_mask_visible).to eq(14)
      expect(described_class.token_dialog_mask_stars).to eq(4)
      expect(described_class.token_dialog_popup_height).to eq(14)
      expect(described_class.token_dialog_popup_min_width).to eq(44)
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
      expect(described_class.message_store_max_cache_history).to eq(200)
    end

    it "reads theme settings" do
      expect(described_class.theme_progress_bar_width).to eq(8)
      expect(described_class.theme_color_success).to eq("green")
      expect(described_class.theme_color_error).to eq("red")
      expect(described_class.theme_border_focused).to eq("yellow")
      expect(described_class.theme_user_message_bg).to eq(22)
      expect(described_class.theme_scrollbar_thumb).to eq("cyan")
    end

    it "reads performance settings" do
      expect(described_class.performance_log_path).to eq("log/tui_performance.log")
    end
  end

  describe ".config_path" do
    it "defaults to ~/.anima/tui.toml" do
      described_class.reset!
      expect(described_class.config_path).to eq(File.expand_path("~/.anima/tui.toml"))
    end

    it "can be overridden" do
      described_class.config_path = template_path
      expect(described_class.config_path).to eq(template_path)
    end

    it "resets to default via reset!" do
      described_class.config_path = template_path
      described_class.reset!
      expect(described_class.config_path).to eq(File.expand_path("~/.anima/tui.toml"))
    end
  end

  describe ".load!" do
    it "raises MissingConfigError when file does not exist" do
      described_class.reset!
      described_class.instance_variable_set(:@config_path, "/nonexistent/tui.toml")
      expect { described_class.load! }.to raise_error(
        TUI::Settings::MissingConfigError, /not found/
      )
    end

    it "raises MissingSettingError for missing key" do
      config_file = Tempfile.new(["tui-config", ".toml"])
      config_file.write("[connection]\ndefault_host = \"localhost\"\n")
      config_file.flush

      described_class.reset!
      described_class.instance_variable_set(:@config_path, config_file.path)
      expect { described_class.load! }.to raise_error(
        TUI::Settings::MissingSettingError, /is not set/
      )
    ensure
      config_file.close
      config_file.unlink
    end

    it "populates ivars from config file" do
      described_class.load!
      expect(described_class.hud_min_width).to eq(24)
    end
  end

  describe ".config_path= triggers load" do
    it "loads settings immediately when path is set" do
      described_class.reset!
      expect(described_class.hud_min_width).to be_nil

      described_class.config_path = template_path
      expect(described_class.hud_min_width).to eq(24)
    end

    it "does not load on nil (reset)" do
      described_class.reset!
      expect(described_class.hud_min_width).to be_nil
    end
  end
end
