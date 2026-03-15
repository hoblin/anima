# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "anima/cli"
require "mcp/config"
require "mcp/health_check"
require "mcp/secrets"
require "credential_store"

RSpec.describe Anima::CLI::Mcp do
  let(:config_dir) { Dir.mktmpdir("anima-mcp-test-") }
  let(:config_path) { File.join(config_dir, "mcp.toml") }
  let(:config) { Mcp::Config.new(path: config_path) }

  before do
    allow(Mcp::Config).to receive(:new).and_return(config)
  end

  after { FileUtils.remove_entry(config_dir) }

  describe "list" do
    context "with no servers configured" do
      it "says no servers configured" do
        expect {
          Anima::CLI.start(["mcp", "list"])
        }.to output(/No MCP servers configured/).to_stdout
      end

      it "suggests the add command" do
        expect {
          Anima::CLI.start(["mcp", "list"])
        }.to output(/anima mcp add/).to_stdout
      end
    end

    context "with configured servers" do
      before do
        File.write(config_path, <<~TOML)
          [servers.sentry]
          transport = "http"
          url = "https://mcp.sentry.dev/mcp"

          [servers.filesystem]
          transport = "stdio"
          command = "mcp-server-filesystem"
          args = ["--root", "/workspace"]
        TOML

        allow(Mcp::HealthCheck).to receive(:call).and_return(
          {status: :connected, tools: 3}
        )
      end

      it "displays each server with transport and detail" do
        expect {
          Anima::CLI.start(["mcp", "list"])
        }.to output(/sentry:.*https:\/\/mcp\.sentry\.dev\/mcp.*\(http\)/).to_stdout
      end

      it "displays stdio servers with command and args" do
        expect {
          Anima::CLI.start(["mcp", "list"])
        }.to output(/filesystem:.*mcp-server-filesystem --root \/workspace.*\(stdio\)/).to_stdout
      end

      it "shows health check status" do
        expect {
          Anima::CLI.start(["mcp", "list"])
        }.to output(/connected \(3 tools\)/).to_stdout
      end
    end

    context "when health check fails" do
      before do
        File.write(config_path, <<~TOML)
          [servers.broken]
          transport = "http"
          url = "http://localhost:9999/mcp"
        TOML

        allow(Mcp::HealthCheck).to receive(:call).and_return(
          {status: :failed, error: "Connection refused"}
        )
      end

      it "shows failure status" do
        expect {
          Anima::CLI.start(["mcp", "list"])
        }.to output(/failed: Connection refused/).to_stdout
      end
    end

    context "with config warnings" do
      before do
        File.write(config_path, <<~TOML)
          [servers.needs_cred]
          transport = "http"
          url = "https://${credential:missing_key}/mcp"
        TOML

        allow(Mcp::Secrets).to receive(:get).and_return(nil)
      end

      it "displays config warnings" do
        expect {
          Anima::CLI.start(["mcp", "list"])
        }.to output(/warning:.*missing_key/).to_stdout
      end

      it "shows config error status for unresolvable servers" do
        expect {
          Anima::CLI.start(["mcp", "list"])
        }.to output(/config error/).to_stdout
      end
    end
  end

  describe "add" do
    context "with an HTTP URL" do
      it "adds an HTTP server to the config" do
        expect {
          Anima::CLI.start(["mcp", "add", "sentry", "https://mcp.sentry.dev/mcp"])
        }.to output(/Added http server 'sentry'/).to_stdout

        servers = config.all_servers
        expect(servers.size).to eq(1)
        expect(servers.first).to include(
          "name" => "sentry",
          "transport" => "http",
          "url" => "https://mcp.sentry.dev/mcp"
        )
      end
    end

    context "with HTTP headers" do
      it "stores headers in the config" do
        expect {
          Anima::CLI.start([
            "mcp", "add",
            "-H", "Authorization: Bearer secret",
            "api", "https://api.example.com/mcp"
          ])
        }.to output(/Added http server 'api'/).to_stdout

        server = config.all_servers.first
        expect(server["headers"]).to eq({"Authorization" => "Bearer secret"})
      end

      it "preserves colons in header values" do
        expect {
          Anima::CLI.start([
            "mcp", "add",
            "-H", "Authorization: Bearer: some:token",
            "api", "https://api.example.com/mcp"
          ])
        }.to output(/Added http server 'api'/).to_stdout

        server = config.all_servers.first
        expect(server["headers"]["Authorization"]).to eq("Bearer: some:token")
      end
    end

    context "with a stdio command" do
      it "adds a stdio server to the config" do
        expect {
          Anima::CLI.start(["mcp", "add", "fs", "--", "mcp-server-filesystem", "--root", "/workspace"])
        }.to output(/Added stdio server 'fs'/).to_stdout

        server = config.all_servers.first
        expect(server).to include(
          "name" => "fs",
          "transport" => "stdio",
          "command" => "mcp-server-filesystem"
        )
        expect(server["args"]).to eq(["--root", "/workspace"])
      end
    end

    context "with stdio env vars" do
      it "stores env vars in the config" do
        expect {
          Anima::CLI.start([
            "mcp", "add",
            "-e", "API_KEY=secret",
            "-e", "DEBUG=true",
            "tool", "--", "my-mcp-tool"
          ])
        }.to output(/Added stdio server 'tool'/).to_stdout

        server = config.all_servers.first
        expect(server["env"]).to eq({"API_KEY" => "secret", "DEBUG" => "true"})
      end
    end

    context "when server already exists" do
      before do
        File.write(config_path, <<~TOML)
          [servers.existing]
          transport = "http"
          url = "http://localhost:3000/mcp"
        TOML
      end

      it "exits with error" do
        expect {
          Anima::CLI.start(["mcp", "add", "existing", "http://other.com/mcp"])
        }.to output(/server 'existing' already exists/).to_stdout.and raise_error(SystemExit)
      end
    end

    context "with invalid server name" do
      it "exits with error for names with spaces" do
        expect {
          Anima::CLI.start(["mcp", "add", "my server", "http://example.com/mcp"])
        }.to output(/invalid server name/).to_stdout.and raise_error(SystemExit)
      end
    end

    context "with no URL or command" do
      it "shows usage and exits" do
        expect {
          Anima::CLI.start(["mcp", "add", "lonely"])
        }.to output(/missing server URL or command/).to_stdout.and raise_error(SystemExit)
      end
    end

    context "preserving existing servers" do
      before do
        File.write(config_path, <<~TOML)
          [servers.existing]
          transport = "http"
          url = "http://localhost:3000/mcp"
        TOML
      end

      it "keeps existing servers when adding a new one" do
        Anima::CLI.start(["mcp", "add", "new_one", "http://new.example.com/mcp"])

        servers = config.all_servers
        expect(servers.size).to eq(2)
        names = servers.map { |s| s["name"] }
        expect(names).to contain_exactly("existing", "new_one")
      end
    end
  end

  describe "remove" do
    before do
      File.write(config_path, <<~TOML)
        [servers.sentry]
        transport = "http"
        url = "https://mcp.sentry.dev/mcp"

        [servers.filesystem]
        transport = "stdio"
        command = "mcp-server-filesystem"
      TOML
    end

    it "removes the named server" do
      expect {
        Anima::CLI.start(["mcp", "remove", "sentry"])
      }.to output(/Removed server 'sentry'/).to_stdout

      servers = config.all_servers
      expect(servers.size).to eq(1)
      expect(servers.first["name"]).to eq("filesystem")
    end

    context "when server does not exist" do
      it "exits with error" do
        expect {
          Anima::CLI.start(["mcp", "remove", "ghost"])
        }.to output(/server 'ghost' not found/).to_stdout.and raise_error(SystemExit)
      end
    end
  end

  describe "add with -s flag" do
    before do
      allow(Mcp::Secrets).to receive(:set)
    end

    it "stores secrets in encrypted credentials" do
      expect(Mcp::Secrets).to receive(:set).with("api_key", "sk-xxx")

      expect {
        Anima::CLI.start([
          "mcp", "add",
          "-s", "api_key=sk-xxx",
          "api", "https://api.example.com/mcp"
        ])
      }.to output(/Added http server 'api'/).to_stdout
    end

    it "stores multiple secrets" do
      expect(Mcp::Secrets).to receive(:set).with("key_one", "val1")
      expect(Mcp::Secrets).to receive(:set).with("key_two", "val2")

      expect {
        Anima::CLI.start([
          "mcp", "add",
          "-s", "key_one=val1",
          "-s", "key_two=val2",
          "api", "https://api.example.com/mcp"
        ])
      }.to output(/Added http server 'api'/).to_stdout
    end

    it "preserves equals signs in secret values" do
      expect(Mcp::Secrets).to receive(:set).with("token", "base64=encoded=value")

      expect {
        Anima::CLI.start([
          "mcp", "add",
          "-s", "token=base64=encoded=value",
          "api", "https://api.example.com/mcp"
        ])
      }.to output(/Added http server 'api'/).to_stdout
    end

    it "exits with error for invalid secret format" do
      expect {
        Anima::CLI.start([
          "mcp", "add",
          "-s", "no_equals_sign",
          "api", "https://api.example.com/mcp"
        ])
      }.to output(/invalid secret format/).to_stdout.and raise_error(SystemExit)
    end

    it "exits with error for invalid secret key characters" do
      expect(Mcp::Secrets).to receive(:set).and_call_original

      expect {
        Anima::CLI.start([
          "mcp", "add",
          "-s", "my-key=value",
          "api", "https://api.example.com/mcp"
        ])
      }.to output(/invalid secret key/).to_stdout.and raise_error(SystemExit)
    end
  end

  describe "secrets" do
    before do
      allow(Mcp::Secrets).to receive(:set)
      allow(Mcp::Secrets).to receive(:list).and_return([])
      allow(Mcp::Secrets).to receive(:remove)
    end

    describe "set" do
      it "stores a secret" do
        expect(Mcp::Secrets).to receive(:set).with("api_key", "sk-xxx")

        expect {
          Anima::CLI.start(["mcp", "secrets", "set", "api_key=sk-xxx"])
        }.to output(/Stored secret 'api_key'/).to_stdout
      end

      it "preserves equals signs in value" do
        expect(Mcp::Secrets).to receive(:set).with("token", "a=b=c")

        expect {
          Anima::CLI.start(["mcp", "secrets", "set", "token=a=b=c"])
        }.to output(/Stored secret 'token'/).to_stdout
      end

      it "exits with error for invalid format" do
        expect {
          Anima::CLI.start(["mcp", "secrets", "set", "no_equals"])
        }.to output(/expected KEY=VALUE/).to_stdout.and raise_error(SystemExit)
      end
    end

    describe "list" do
      context "with no secrets" do
        it "says no secrets stored" do
          expect {
            Anima::CLI.start(["mcp", "secrets", "list"])
          }.to output(/No MCP secrets stored/).to_stdout
        end

        it "suggests the set command" do
          expect {
            Anima::CLI.start(["mcp", "secrets", "list"])
          }.to output(/anima mcp secrets set/).to_stdout
        end
      end

      context "with stored secrets" do
        before do
          allow(Mcp::Secrets).to receive(:list).and_return(["api_key", "token"])
        end

        it "lists secret names" do
          expect {
            Anima::CLI.start(["mcp", "secrets", "list"])
          }.to output(/api_key.*token/m).to_stdout
        end
      end
    end

    describe "remove" do
      it "removes a stored secret" do
        allow(Mcp::Secrets).to receive(:list).and_return(["api_key"])
        expect(Mcp::Secrets).to receive(:remove).with("api_key")

        expect {
          Anima::CLI.start(["mcp", "secrets", "remove", "api_key"])
        }.to output(/Removed secret 'api_key'/).to_stdout
      end

      it "exits with error when secret not found" do
        allow(Mcp::Secrets).to receive(:list).and_return([])

        expect {
          Anima::CLI.start(["mcp", "secrets", "remove", "ghost"])
        }.to output(/secret 'ghost' not found/).to_stdout.and raise_error(SystemExit)
      end
    end
  end
end
