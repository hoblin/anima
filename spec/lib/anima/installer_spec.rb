# frozen_string_literal: true

require "spec_helper"
require "anima/installer"
require "tmpdir"

RSpec.describe Anima::Installer do
  describe "DIRECTORIES" do
    it "includes expected directories" do
      expect(described_class::DIRECTORIES).to include("db", "config/credentials", "log", "tmp")
    end
  end

  describe "ANIMA_HOME" do
    it "points to ~/.anima" do
      expect(described_class::ANIMA_HOME.to_s).to eq(File.expand_path("~/.anima"))
    end
  end

  describe "#run" do
    let(:tmp_home) { Pathname.new(Dir.mktmpdir("anima-test-")) }
    let(:installer) { described_class.new(anima_home: tmp_home) }

    after { FileUtils.rm_rf(tmp_home) }

    before do
      allow(installer).to receive(:create_systemd_service)
    end

    it "creates all expected directories" do
      installer.run

      described_class::DIRECTORIES.each do |dir|
        expect(tmp_home.join(dir)).to be_directory
      end
    end

    it "creates anima.yml config file" do
      installer.run

      config_path = tmp_home.join("config", "anima.yml")
      expect(config_path).to exist
    end

    it "generates credentials for each environment" do
      installer.run

      %w[production development test].each do |env|
        expect(tmp_home.join("config", "credentials", "#{env}.yml.enc")).to exist
        expect(tmp_home.join("config", "credentials", "#{env}.key")).to exist
      end
    end

    it "sets restrictive permissions on credential key files" do
      installer.run

      %w[production development test].each do |env|
        key_path = tmp_home.join("config", "credentials", "#{env}.key")
        expect(key_path.stat.mode & 0o777).to eq(0o600)
      end
    end

    it "sets restrictive permissions on encrypted credential files" do
      installer.run

      %w[production development test].each do |env|
        enc_path = tmp_home.join("config", "credentials", "#{env}.yml.enc")
        expect(enc_path.stat.mode & 0o777).to eq(0o600)
      end
    end

    it "is idempotent" do
      installer.run
      expect { installer.run }.not_to raise_error
    end

    it "does not overwrite existing credentials on re-run" do
      installer.run
      original_key = tmp_home.join("config", "credentials", "production.key").read

      installer.run
      expect(tmp_home.join("config", "credentials", "production.key").read).to eq(original_key)
    end
  end
end
