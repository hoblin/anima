# frozen_string_literal: true

require "spec_helper"
require "anima/cli"
require "anima/brain_server"

RSpec.describe Anima::CLI do
  describe "version" do
    it "prints the version" do
      expect { described_class.start(["version"]) }.to output(/anima #{Anima::VERSION}/o).to_stdout
    end
  end

  describe "start" do
    it "rejects invalid environment" do
      expect {
        described_class.start(["start", "-e", "bogus"])
      }.to output(/Invalid environment: bogus/).to_stdout.and raise_error(SystemExit)
    end

    it "requires anima to be installed" do
      allow(File).to receive(:directory?).and_call_original
      allow(File).to receive(:directory?).with(File.expand_path("~/.anima")).and_return(false)

      expect {
        described_class.start(["start"])
      }.to output(/Run 'anima install' first/).to_stdout.and raise_error(SystemExit)
    end

    it "delegates to BrainServer" do
      brain = instance_double(Anima::BrainServer, run: nil)
      allow(Anima::BrainServer).to receive(:new).and_return(brain)

      with_env("RAILS_ENV" => nil) do
        described_class.start(["start"])
      end

      expect(Anima::BrainServer).to have_received(:new).with(environment: "development")
      expect(brain).to have_received(:run)
    end

    it "respects RAILS_ENV when no flag is given" do
      brain = instance_double(Anima::BrainServer, run: nil)
      allow(Anima::BrainServer).to receive(:new).and_return(brain)

      with_env("RAILS_ENV" => "production") do
        described_class.start(["start"])
      end

      expect(Anima::BrainServer).to have_received(:new).with(environment: "production")
    end

    it "prefers -e flag over RAILS_ENV" do
      brain = instance_double(Anima::BrainServer, run: nil)
      allow(Anima::BrainServer).to receive(:new).and_return(brain)

      with_env("RAILS_ENV" => "production") do
        described_class.start(["start", "-e", "test"])
      end

      expect(Anima::BrainServer).to have_received(:new).with(environment: "test")
    end
  end

  describe "install" do
    it "delegates to Installer" do
      installer = instance_double(Anima::Installer, run: nil)
      allow(Anima::Installer).to receive(:new).and_return(installer)

      described_class.start(["install"])

      expect(installer).to have_received(:run)
    end
  end

  describe "tui" do
    it "delegates to TUI::App" do
      tui_app = instance_double(TUI::App, run: nil)
      allow(TUI::App).to receive(:new).and_return(tui_app)

      described_class.start(["tui"])

      expect(tui_app).to have_received(:run)
    end
  end
end
