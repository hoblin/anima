# frozen_string_literal: true

require "spec_helper"
require "anima/cli"
require "anima/installer"

RSpec.describe Anima::CLI do
  describe "version" do
    it "prints the version" do
      expect { described_class.start(["version"]) }.to output(/anima #{Anima::VERSION}/o).to_stdout
    end
  end

  describe "start" do
    let(:gem_root) { Anima.gem_root }

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

    context "when installed" do
      before do
        allow(File).to receive(:directory?).and_call_original
        allow(File).to receive(:directory?).with(File.expand_path("~/.anima")).and_return(true)
        # Stub Kernel methods to avoid Thor method_added warnings
        allow_any_instance_of(Kernel).to receive(:system)
          .with(gem_root.join("bin/rails").to_s, "db:prepare", chdir: gem_root.to_s).and_return(true)
        allow_any_instance_of(Kernel).to receive(:exec)
          .with("foreman", "start", "-f", gem_root.join("Procfile").to_s, "-p", described_class::DEFAULT_PORT.to_s, chdir: gem_root.to_s)
      end

      it "runs db:prepare then starts foreman with correct port" do
        expect_any_instance_of(Kernel).to receive(:exec)
          .with("foreman", "start", "-f", gem_root.join("Procfile").to_s, "-p", described_class::DEFAULT_PORT.to_s, chdir: gem_root.to_s)

        described_class.start(["start"])
      end

      it "respects RAILS_ENV when no -e flag given" do
        with_env("RAILS_ENV" => "production") do
          described_class.start(["start"])
          expect(ENV["RAILS_ENV"]).to eq("production")
        end
      end

      it "aborts when db:prepare fails" do
        allow_any_instance_of(Kernel).to receive(:system)
          .with(gem_root.join("bin/rails").to_s, "db:prepare", chdir: gem_root.to_s).and_return(false)

        expect {
          described_class.start(["start"])
        }.to raise_error(SystemExit)
      end
    end
  end

  describe "tui" do
    it "connects without a REST session fetch" do
      cable_client = instance_double(TUI::CableClient, connect: nil, disconnect: nil, status: :subscribed)
      allow(TUI::CableClient).to receive(:new).with(host: "localhost:19999").and_return(cable_client)

      app = instance_double(TUI::App, run: nil)
      allow(TUI::App).to receive(:new).and_return(app)

      expect {
        described_class.start(["tui", "--host", "localhost:19999"])
      }.to output(/Connecting to brain/).to_stdout

      expect(TUI::CableClient).to have_received(:new).with(host: "localhost:19999")
      expect(cable_client).to have_received(:connect)
      expect(TUI::App).to have_received(:new).with(cable_client: cable_client)
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
end
