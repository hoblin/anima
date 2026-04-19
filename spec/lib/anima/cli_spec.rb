# frozen_string_literal: true

require "spec_helper"
require "anima/cli"
require "anima/installer"
require "anima/config_migrator"
require "anima/spinner"
require "tui/cable_client"
require "tui/app"

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

    context "when installed", :silence_output do
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
      expect(TUI::App).to have_received(:new).with(cable_client: cable_client, debug: false)
    end

    it "passes debug: true when --debug flag is given" do
      cable_client = instance_double(TUI::CableClient, connect: nil, disconnect: nil, status: :subscribed)
      allow(TUI::CableClient).to receive(:new).with(host: "localhost:19999").and_return(cable_client)

      app = instance_double(TUI::App, run: nil)
      allow(TUI::App).to receive(:new).and_return(app)

      expect {
        described_class.start(["tui", "--host", "localhost:19999", "--debug"])
      }.to output(/Connecting to brain/).to_stdout

      expect(TUI::App).to have_received(:new).with(cable_client: cable_client, debug: true)
    end
  end

  describe "update" do
    let(:addition) { Anima::ConfigMigrator::Addition.new(section: "llm", key: "temperature", value: 0.7) }

    before do
      allow_any_instance_of(Kernel).to receive(:system).and_return(false)
    end

    context "without --migrate-only" do
      it "exits with error when gem update fails" do
        allow_any_instance_of(Kernel).to receive(:system)
          .with("gem", "update", "anima-core", out: File::NULL, err: File::NULL).and_return(false)

        expect {
          described_class.start(["update"])
        }.to output(/Run manually for details: gem update anima-core/).to_stdout.and raise_error(SystemExit)
      end

      it "re-execs with --migrate-only after successful gem update", :silence_output do
        allow_any_instance_of(Kernel).to receive(:system)
          .with("gem", "update", "anima-core", out: File::NULL, err: File::NULL).and_return(true)

        # exec replaces the process; simulate by raising SystemExit
        expect_any_instance_of(Kernel).to receive(:exec)
          .with(File.join(Gem.bindir, "anima"), "update", "--migrate-only")
          .and_raise(SystemExit.new(0))

        expect {
          described_class.start(["update"])
        }.to raise_error(SystemExit)
      end
    end

    context "with --migrate-only" do
      context "when config is up to date" do
        before do
          allow(Anima::ConfigMigrator).to receive_message_chain(:new, :run)
            .and_return(Anima::ConfigMigrator::Result.new(status: :up_to_date, additions: []))
        end

        it "restarts the service when it is active" do
          allow_any_instance_of(Kernel).to receive(:system)
            .with("systemctl", "--user", "is-active", "--quiet", "anima.service").and_return(true)
          allow_any_instance_of(Kernel).to receive(:system)
            .with("systemctl", "--user", "restart", "anima.service").and_return(true)

          expect {
            described_class.start(["update", "--migrate-only"])
          }.to output(/✓ Restarting anima service/m).to_stdout
        end

        it "skips restart when the service is not active" do
          expect {
            described_class.start(["update", "--migrate-only"])
          }.not_to output(/Restarting/).to_stdout
        end

        it "reports failure when restart fails" do
          allow_any_instance_of(Kernel).to receive(:system)
            .with("systemctl", "--user", "is-active", "--quiet", "anima.service").and_return(true)
          allow_any_instance_of(Kernel).to receive(:system)
            .with("systemctl", "--user", "restart", "anima.service").and_return(false)

          expect {
            described_class.start(["update", "--migrate-only"])
          }.to output(/✗ Restarting anima service.*Run manually/m).to_stdout
        end
      end

      context "when config is updated" do
        before do
          allow(Anima::ConfigMigrator).to receive_message_chain(:new, :run)
            .and_return(Anima::ConfigMigrator::Result.new(status: :updated, additions: [addition]))
        end

        it "reports added keys and restarts the service" do
          allow_any_instance_of(Kernel).to receive(:system)
            .with("systemctl", "--user", "is-active", "--quiet", "anima.service").and_return(true)
          allow_any_instance_of(Kernel).to receive(:system)
            .with("systemctl", "--user", "restart", "anima.service").and_return(true)

          expect {
            described_class.start(["update", "--migrate-only"])
          }.to output(/\[llm\] temperature.*✓ Restarting anima service/m).to_stdout
        end
      end

      context "when config file is not found" do
        before do
          allow(Anima::ConfigMigrator).to receive_message_chain(:new, :run)
            .and_return(Anima::ConfigMigrator::Result.new(status: :not_found, additions: []))
        end

        it "exits with an error" do
          expect {
            described_class.start(["update", "--migrate-only"])
          }.to output(/Run 'anima install' first/).to_stdout.and raise_error(SystemExit)
        end
      end
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
