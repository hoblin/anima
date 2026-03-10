# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
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
          .with(gem_root.join("bin/rails").to_s, "db:prepare").and_return(true)
        allow_any_instance_of(Kernel).to receive(:exec)
          .with("foreman", "start", "-f", gem_root.join("Procfile").to_s)
      end

      it "runs db:prepare then starts foreman" do
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
          .with(gem_root.join("bin/rails").to_s, "db:prepare").and_return(false)

        expect {
          described_class.start(["start"])
        }.to raise_error(SystemExit)
      end
    end
  end

  describe "tui" do
    it "exits with error when brain is not running" do
      stub_request(:get, "http://localhost:19999/api/sessions/current")
        .to_raise(Errno::ECONNREFUSED)

      expect {
        described_class.start(["tui", "--host", "localhost:19999"])
      }.to output(/Cannot connect to brain/).to_stdout.and raise_error(SystemExit)
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
