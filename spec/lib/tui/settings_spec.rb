# frozen_string_literal: true

require "spec_helper"
require "tui/settings"
require "tempfile"

RSpec.describe TUI::Settings do
  let(:template_path) { File.expand_path("../../../templates/tui.toml", __dir__) }

  after { described_class.reset! }

  describe ".load!" do
    it "raises MissingConfigError when the file is absent" do
      described_class.instance_variable_set(:@config_path, "/nonexistent/tui.toml")
      expect { described_class.load! }.to raise_error(
        TUI::Settings::MissingConfigError, /not found/
      )
    end

    it "raises MissingSettingError when the file is missing a template key" do
      partial = Tempfile.new(["tui-config", ".toml"])
      partial.write(%([connection]\ndefault_host = "localhost"\n))
      partial.flush
      described_class.instance_variable_set(:@config_path, partial.path)

      expect { described_class.load! }.to raise_error(
        TUI::Settings::MissingSettingError, /is not set/
      )
    ensure
      partial&.close
      partial&.unlink
    end

    it "populates ivars from the configured file" do
      described_class.config_path = template_path
      expect(described_class.hud_min_width).to eq(TUI::Settings::TEMPLATE["hud"]["min_width"])
    end
  end

  describe ".config_path=" do
    it "triggers load! when assigned a path" do
      expect(described_class).to receive(:load!).and_call_original
      described_class.config_path = template_path
    end

    it "does not trigger load! when assigned nil" do
      expect(described_class).not_to receive(:load!)
      described_class.config_path = nil
    end
  end
end
