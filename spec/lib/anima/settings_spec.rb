# frozen_string_literal: true

require "rails_helper"

RSpec.describe Anima::Settings do
  let(:full_config) do
    {
      "llm" => {
        "model" => "claude-sonnet-4-20250514",
        "fast_model" => "claude-haiku-4-5",
        "max_tokens" => 8192,
        "max_tool_rounds" => 25,
        "token_budget" => 190_000
      },
      "timeouts" => {"api" => 30, "command" => 30, "mcp_response" => 60, "web_request" => 10},
      "shell" => {"max_output_bytes" => 100_000},
      "tools" => {"max_file_size" => 10_485_760, "max_read_lines" => 2_000, "max_read_bytes" => 50_000, "max_web_response_bytes" => 100_000},
      "session" => {"name_generation_interval" => 30}
    }
  end

  before { allow(described_class).to receive(:config).and_return(full_config) }

  describe "accessors read from config" do
    it "reads LLM settings" do
      expect(described_class.model).to eq("claude-sonnet-4-20250514")
      expect(described_class.fast_model).to eq("claude-haiku-4-5")
      expect(described_class.max_tokens).to eq(8192)
      expect(described_class.max_tool_rounds).to eq(25)
      expect(described_class.token_budget).to eq(190_000)
    end

    it "reads timeout settings" do
      expect(described_class.api_timeout).to eq(30)
      expect(described_class.command_timeout).to eq(30)
      expect(described_class.mcp_response_timeout).to eq(60)
      expect(described_class.web_request_timeout).to eq(10)
    end

    it "reads shell, tool, and session settings" do
      expect(described_class.max_output_bytes).to eq(100_000)
      expect(described_class.max_file_size).to eq(10_485_760)
      expect(described_class.max_read_lines).to eq(2_000)
      expect(described_class.max_read_bytes).to eq(50_000)
      expect(described_class.max_web_response_bytes).to eq(100_000)
      expect(described_class.name_generation_interval).to eq(30)
    end
  end

  describe "missing config file" do
    before do
      allow(described_class).to receive(:config).and_raise(
        Anima::Settings::MissingConfigError, "Config file not found: /missing/config.toml. Run `anima install` to create it."
      )
    end

    it "raises MissingConfigError" do
      expect { described_class.model }.to raise_error(
        Anima::Settings::MissingConfigError, /not found/
      )
    end
  end

  describe "missing setting" do
    before do
      allow(described_class).to receive(:config).and_return(
        "llm" => {"model" => "claude-sonnet-4-20250514"}
      )
    end

    it "raises MissingSettingError for absent key" do
      expect { described_class.api_timeout }.to raise_error(
        Anima::Settings::MissingSettingError, /\[timeouts\] api is not set/
      )
    end

    it "raises MissingSettingError for absent key in present section" do
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

    it "can be overridden" do
      described_class.config_path = "/custom/path.toml"
      expect(described_class.config_path).to eq("/custom/path.toml")
    end

    it "resets to default via reset!" do
      described_class.config_path = "/custom/path.toml"
      described_class.reset!
      expect(described_class.config_path).to eq(File.expand_path("~/.anima/config.toml"))
    end
  end
end
