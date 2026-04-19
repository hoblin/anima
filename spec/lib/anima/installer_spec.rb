# frozen_string_literal: true

require "spec_helper"
require "anima/installer"
require "tmpdir"

RSpec.describe Anima::Installer do
  describe "#run", :silence_output do
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

    it "creates config.toml from template with resolved paths" do
      installer.run

      config_path = tmp_home.join("config.toml")
      expect(config_path).to exist

      content = config_path.read
      expect(content).to include("[llm]")
      expect(content).to include("soul = \"#{tmp_home.join("soul.md")}\"")
      expect(content).not_to include("{{ANIMA_HOME}}")
      expect { TomlRB.parse(content) }.not_to raise_error
    end

    it "does not overwrite existing config.toml on re-run" do
      FileUtils.mkdir_p(tmp_home)
      config_path = tmp_home.join("config.toml")
      config_path.write("[llm]\nmodel = \"custom-model\"\n")

      installer.run

      expect(config_path.read).to include('model = "custom-model"')
    end

    it "creates tui.toml from template" do
      installer.run

      tui_path = tmp_home.join("tui.toml")
      expect(tui_path).to exist

      content = tui_path.read
      expect(content).to include("[connection]")
      expect(content).to include("[hud]")
      expect(content).to include("[chat]")
      expect { TomlRB.parse(content) }.not_to raise_error
    end

    it "does not overwrite existing tui.toml on re-run" do
      FileUtils.mkdir_p(tmp_home)
      tui_path = tmp_home.join("tui.toml")
      tui_path.write("[hud]\nmin_width = 42\n")

      installer.run

      expect(tui_path.read).to include("min_width = 42")
    end

    it "creates mcp.toml config file" do
      installer.run

      mcp_path = tmp_home.join("mcp.toml")
      expect(mcp_path).to exist
      expect(mcp_path.read).to include("[servers.example]")
    end

    it "includes Active Record Encryption keys in credentials" do
      installer.run

      %w[production development test].each do |env|
        content_path = tmp_home.join("config", "credentials", "#{env}.yml.enc")
        key_path = tmp_home.join("config", "credentials", "#{env}.key")

        config = ActiveSupport::EncryptedConfiguration.new(
          config_path: content_path.to_s,
          key_path: key_path.to_s,
          env_key: "RAILS_MASTER_KEY",
          raise_if_missing_key: true
        )
        creds = config.read
        parsed = YAML.safe_load(creds)

        expect(parsed).to have_key("active_record_encryption")
        expect(parsed["active_record_encryption"]).to include(
          "primary_key", "deterministic_key", "key_derivation_salt"
        )
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

  describe "#create_systemd_service", :silence_output do
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

    it "updates service file when content has changed" do
      service_path.write("old content")

      installer.create_systemd_service

      expect(service_path.read).to include("anima start -e production")
    end

    it "preserves service file when content is unchanged" do
      installer.create_systemd_service
      original = service_path.read

      installer.create_systemd_service

      expect(service_path.read).to eq(original)
    end

    it "always runs daemon-reload and enable even when service exists" do
      service_path.write("existing")

      installer.create_systemd_service

      expect(installer).to have_received(:system)
        .with("systemctl", "--user", "daemon-reload", err: File::NULL, out: File::NULL)
      expect(installer).to have_received(:system)
        .with("systemctl", "--user", "enable", "--now", "anima.service", err: File::NULL, out: File::NULL)
    end
  end
end
