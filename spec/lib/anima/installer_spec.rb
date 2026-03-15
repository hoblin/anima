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

    it "creates soul.md from template" do
      installer.run

      soul_path = tmp_home.join("soul.md")
      expect(soul_path).to exist
      expect(soul_path.read).to include("You've just woken up in a new body")
    end

    it "does not overwrite existing soul.md on re-run" do
      soul_path = tmp_home.join("soul.md")
      FileUtils.mkdir_p(tmp_home)
      soul_path.write("I am who I chose to be.")

      installer.run

      expect(soul_path.read).to eq("I am who I chose to be.")
    end

    it "creates mcp.toml config file" do
      installer.run

      mcp_path = tmp_home.join("mcp.toml")
      expect(mcp_path).to exist
      expect(mcp_path.read).to include("[servers.example]")
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

  describe "#create_systemd_service" do
    let(:tmp_home) { Pathname.new(Dir.mktmpdir("anima-test-")) }
    let(:installer) { described_class.new(anima_home: tmp_home) }
    let(:service_dir) { Pathname.new(Dir.mktmpdir("systemd-test-")) }
    let(:service_path) { service_dir.join("anima.service") }

    after do
      FileUtils.rm_rf(tmp_home)
      FileUtils.rm_rf(service_dir)
    end

    before do
      allow(Pathname).to receive(:new).and_call_original
      allow(Pathname).to receive(:new)
        .with(File.expand_path("~/.config/systemd/user"))
        .and_return(service_dir)
      allow(installer).to receive(:system)
    end

    it "passes -e production to anima start" do
      installer.create_systemd_service

      content = service_path.read
      expect(content).to include("anima start -e production")
    end

    it "does not set RAILS_ENV via Environment directive" do
      installer.create_systemd_service

      content = service_path.read
      expect(content).not_to include("Environment=RAILS_ENV")
    end

    it "uses Type=simple for process management" do
      installer.create_systemd_service

      content = service_path.read
      expect(content).to include("Type=simple")
    end

    it "reloads systemd then enables and starts the service" do
      installer.create_systemd_service

      expect(installer).to have_received(:system)
        .with("systemctl", "--user", "daemon-reload", err: File::NULL, out: File::NULL).ordered
      expect(installer).to have_received(:system)
        .with("systemctl", "--user", "enable", "--now", "anima.service", err: File::NULL, out: File::NULL).ordered
    end

    it "skips creation when service already exists" do
      service_path.write("existing")

      installer.create_systemd_service

      expect(service_path.read).to eq("existing")
    end
  end
end
