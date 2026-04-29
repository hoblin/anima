# frozen_string_literal: true

require "rails_helper"

RSpec.describe Anima::Settings do
  describe ".default_view_mode" do
    it "accepts every Session::VIEW_MODES value" do
      Session::VIEW_MODES.each do |mode|
        allow(described_class).to receive(:config).and_return("session" => {"default_view_mode" => mode})
        expect(described_class.default_view_mode).to eq(mode)
      end
    end

    it "rejects values outside Session::VIEW_MODES" do
      allow(described_class).to receive(:config).and_return("session" => {"default_view_mode" => "fancy"})

      expect { described_class.default_view_mode }.to raise_error(
        Anima::Settings::MissingSettingError, /must be one of/
      )
    end
  end

  describe ".interrupt_check_interval" do
    it "enforces a 0.5s floor when the configured value is lower" do
      allow(described_class).to receive(:config).and_return("timeouts" => {"interrupt_check" => 0.1})
      expect(described_class.interrupt_check_interval).to eq(0.5)
    end

    it "passes through values above the floor" do
      allow(described_class).to receive(:config).and_return("timeouts" => {"interrupt_check" => 2})
      expect(described_class.interrupt_check_interval).to eq(2)
    end
  end

  describe "missing config file" do
    before do
      allow(described_class).to receive(:config).and_raise(
        Anima::Settings::MissingConfigError, "Config file not found: /missing/config.toml. Run `anima install` to create it."
      )
    end

    it "propagates MissingConfigError from getters" do
      expect { described_class.model }.to raise_error(Anima::Settings::MissingConfigError, /not found/)
    end
  end

  describe "missing key" do
    before do
      allow(described_class).to receive(:config).and_return("llm" => {"model" => "claude-sonnet-4-20250514"})
    end

    it "raises MissingSettingError when the section is absent" do
      expect { described_class.api_timeout }.to raise_error(
        Anima::Settings::MissingSettingError, /\[timeouts\] api is not set/
      )
    end

    it "raises MissingSettingError when the key is absent from a present section" do
      expect { described_class.fast_model }.to raise_error(
        Anima::Settings::MissingSettingError, /\[llm\] fast_model is not set/
      )
    end
  end

  describe ".config_path" do
    after { described_class.reset! }

    it "defaults to ~/.anima/config.toml" do
      expect(described_class.config_path).to eq(File.expand_path("~/.anima/config.toml"))
    end

    it "resets to default via reset!" do
      described_class.config_path = "/custom/path.toml"
      described_class.reset!
      expect(described_class.config_path).to eq(File.expand_path("~/.anima/config.toml"))
    end
  end

  describe "hot-reload" do
    let(:config_file) { Tempfile.new(["anima-config", ".toml"]) }

    def write_config(model:)
      config_file.reopen(config_file.path, "w")
      config_file.write(<<~TOML)
        [llm]
        model = "#{model}"
        fast_model = "fast-v1"
        max_tokens = 100
        max_tool_rounds = 5
        token_budget = 1000
        [timeouts]
        api = 10
        command = 10
        mcp_response = 10
        web_request = 10
        [shell]
        max_output_bytes = 1000
        [tools]
        max_file_size = 1000
        max_read_lines = 100
        max_read_bytes = 1000
        max_web_response_bytes = 1000
        [session]
        default_view_mode = "basic"
        [melete]
        max_tokens = 128
        message_window = 20
      TOML
      config_file.flush
    end

    before do
      allow(described_class).to receive(:config).and_call_original
      write_config(model: "model-v1")
      described_class.config_path = config_file.path
    end

    after do
      described_class.reset!
      config_file.close
      config_file.unlink
    end

    it "reads values from a real TOML file" do
      expect(described_class.model).to eq("model-v1")
      expect(described_class.api_timeout).to eq(10)
    end

    it "picks up changes when the file is modified" do
      expect(described_class.model).to eq("model-v1")

      write_config(model: "model-v2")
      FileUtils.touch(config_file.path, mtime: Time.now + 1)

      expect(described_class.model).to eq("model-v2")
    end

    it "does not re-parse TOML when the file has not changed" do
      described_class.model
      expect(TomlRB).not_to receive(:load_file)
      2.times { described_class.model }
    end
  end
end
