# frozen_string_literal: true

require "rails_helper"

RSpec.describe Anima::Settings do
  let(:full_config) do
    {
      "llm" => {
        "model" => "claude-sonnet-4-20250514",
        "fast_model" => "claude-haiku-4-5",
        "max_tokens" => 8192,
        "max_tool_rounds" => 500,
        "token_budget" => 190_000
      },
      "timeouts" => {"api" => 300, "command" => 30, "mcp_response" => 60, "web_request" => 10},
      "shell" => {"max_output_bytes" => 100_000},
      "tools" => {"max_file_size" => 10_485_760, "max_read_lines" => 2_000, "max_read_bytes" => 50_000, "max_web_response_bytes" => 100_000},
      "paths" => {"soul" => "/home/test/.anima/soul.md"},
      "session" => {"default_view_mode" => "basic", "name_generation_interval" => 30},
      "analytical_brain" => {"max_tokens" => 128, "blocking_on_user_message" => true, "blocking_on_agent_message" => false, "event_window" => 20},
      "environment" => {"project_files" => ["CLAUDE.md", "AGENTS.md", "README.md", "CONTRIBUTING.md"], "project_files_max_depth" => 3},
      "github" => {"repo" => "hoblin/anima", "label" => "anima-wants"}
    }
  end

  before { allow(described_class).to receive(:config).and_return(full_config) }

  describe "accessors read from config" do
    it "reads LLM settings" do
      expect(described_class.model).to eq("claude-sonnet-4-20250514")
      expect(described_class.fast_model).to eq("claude-haiku-4-5")
      expect(described_class.max_tokens).to eq(8192)
      expect(described_class.max_tool_rounds).to eq(500)
      expect(described_class.token_budget).to eq(190_000)
    end

    it "reads timeout settings" do
      expect(described_class.api_timeout).to eq(300)
      expect(described_class.command_timeout).to eq(30)
      expect(described_class.mcp_response_timeout).to eq(60)
      expect(described_class.web_request_timeout).to eq(10)
    end

    it "reads path settings" do
      expect(described_class.soul_path).to eq("/home/test/.anima/soul.md")
    end

    it "reads shell, tool, and session settings" do
      expect(described_class.max_output_bytes).to eq(100_000)
      expect(described_class.max_file_size).to eq(10_485_760)
      expect(described_class.max_read_lines).to eq(2_000)
      expect(described_class.max_read_bytes).to eq(50_000)
      expect(described_class.max_web_response_bytes).to eq(100_000)
      expect(described_class.default_view_mode).to eq("basic")
      expect(described_class.name_generation_interval).to eq(30)
    end

    it "reads analytical brain settings" do
      expect(described_class.analytical_brain_max_tokens).to eq(128)
      expect(described_class.analytical_brain_blocking_on_user_message).to be true
      expect(described_class.analytical_brain_blocking_on_agent_message).to be false
      expect(described_class.analytical_brain_event_window).to eq(20)
    end

    it "reads environment settings" do
      expect(described_class.project_files_whitelist).to eq(["CLAUDE.md", "AGENTS.md", "README.md", "CONTRIBUTING.md"])
      expect(described_class.project_files_max_depth).to eq(3)
    end

    it "reads GitHub settings" do
      expect(described_class.github_repo).to eq("hoblin/anima")
      expect(described_class.github_label).to eq("anima-wants")
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

  describe "default_view_mode validation" do
    it "accepts all valid view modes" do
      Session::VIEW_MODES.each do |mode|
        allow(described_class).to receive(:config).and_return(
          "session" => {"default_view_mode" => mode}
        )

        expect(described_class.default_view_mode).to eq(mode)
      end
    end

    it "rejects invalid view mode values" do
      allow(described_class).to receive(:config).and_return(
        "session" => {"default_view_mode" => "fancy"}
      )

      expect { described_class.default_view_mode }.to raise_error(
        Anima::Settings::MissingSettingError, /must be one of/
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

  describe "hot-reload" do
    let(:config_file) { Tempfile.new(["anima-config", ".toml"]) }

    before do
      allow(described_class).to receive(:config).and_call_original
      config_file.write(<<~TOML)
        [llm]
        model = "model-v1"
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
        name_generation_interval = 5
        [analytical_brain]
        max_tokens = 128
        blocking_on_user_message = true
        blocking_on_agent_message = false
        event_window = 20
        [environment]
        project_files = ["CLAUDE.md", "README.md"]
        project_files_max_depth = 3
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
      expect(described_class.model).to eq("model-v1")
      expect(described_class.api_timeout).to eq(10)
    end

    it "picks up changes when the file is modified" do
      expect(described_class.model).to eq("model-v1")

      # Ensure mtime changes (filesystem granularity can be 1 second)
      sleep 0.01
      config_file.reopen(config_file.path, "w")
      config_file.write(<<~TOML)
        [llm]
        model = "model-v2"
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
        name_generation_interval = 5
        [analytical_brain]
        max_tokens = 128
        blocking_on_user_message = true
        blocking_on_agent_message = false
        event_window = 20
      TOML
      config_file.flush
      FileUtils.touch(config_file.path, mtime: Time.now + 1)

      expect(described_class.model).to eq("model-v2")
    end

    it "does not re-parse TOML when file has not changed" do
      described_class.model
      expect(TomlRB).not_to receive(:load_file)
      2.times { described_class.model }
    end
  end
end
