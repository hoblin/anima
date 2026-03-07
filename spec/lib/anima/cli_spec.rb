# frozen_string_literal: true

require "spec_helper"
require "anima/cli"

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
