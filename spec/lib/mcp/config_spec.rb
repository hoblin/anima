# frozen_string_literal: true

require "rails_helper"

RSpec.describe Mcp::Config do
  let(:config_dir) { Dir.mktmpdir }
  let(:config_path) { File.join(config_dir, "mcp.toml") }

  subject(:config) { described_class.new(path: config_path) }

  after { FileUtils.remove_entry(config_dir) }

  describe "#http_servers" do
    context "when config file does not exist" do
      let(:config_path) { File.join(config_dir, "nonexistent.toml") }

      it "returns an empty array" do
        expect(config.http_servers).to eq([])
      end
    end

    context "when config file is empty" do
      before { File.write(config_path, "") }

      it "returns an empty array" do
        expect(config.http_servers).to eq([])
      end
    end

    context "with HTTP server entries" do
      before do
        File.write(config_path, <<~TOML)
          [servers.mythonix]
          transport = "http"
          url = "http://localhost:3000/mcp/v2"

          [servers.linear]
          transport = "http"
          url = "https://mcp.linear.app/mcp"
          headers = { Authorization = "Bearer test-token" }
        TOML
      end

      it "returns all HTTP server configs" do
        expect(config.http_servers.size).to eq(2)
      end

      it "parses server name and url" do
        mythonix = config.http_servers.find { |s| s[:name] == "mythonix" }

        expect(mythonix[:url]).to eq("http://localhost:3000/mcp/v2")
        expect(mythonix[:headers]).to eq({})
      end

      it "parses inline headers" do
        linear = config.http_servers.find { |s| s[:name] == "linear" }

        expect(linear[:headers]).to eq({"Authorization" => "Bearer test-token"})
      end
    end

    context "with non-HTTP transports" do
      before do
        File.write(config_path, <<~TOML)
          [servers.local_tool]
          transport = "stdio"
          command = "my-tool"

          [servers.web_api]
          transport = "http"
          url = "http://localhost:8080/mcp"
        TOML
      end

      it "skips non-HTTP servers silently" do
        servers = config.http_servers

        expect(servers.size).to eq(1)
        expect(servers.first[:name]).to eq("web_api")
      end
    end

    context "with credential interpolation" do
      before do
        File.write(config_path, <<~TOML)
          [servers.api]
          transport = "http"
          url = "https://${credential:mcp_host}/mcp"
          headers = { Authorization = "Bearer ${credential:mcp_token}" }
        TOML
      end

      it "replaces ${credential:key} placeholders in urls" do
        allow(Mcp::Secrets).to receive(:get).with("mcp_host").and_return("api.example.com")
        allow(Mcp::Secrets).to receive(:get).with("mcp_token").and_return("secret-123")

        servers = config.http_servers

        expect(servers.first[:url]).to eq("https://api.example.com/mcp")
      end

      it "replaces ${credential:key} placeholders in headers" do
        allow(Mcp::Secrets).to receive(:get).with("mcp_host").and_return("api.example.com")
        allow(Mcp::Secrets).to receive(:get).with("mcp_token").and_return("secret-123")

        servers = config.http_servers

        expect(servers.first[:headers]["Authorization"]).to eq("Bearer secret-123")
      end

      it "skips servers with missing credentials and collects a warning" do
        allow(Mcp::Secrets).to receive(:get).and_return(nil)

        expect(config.http_servers).to eq([])
        expect(config.warnings).to include(match(/api.*missing credential.*mcp_host/))
      end
    end

    context "with multiple credential placeholders in a single value" do
      before do
        File.write(config_path, <<~TOML)
          [servers.multi]
          transport = "http"
          url = "https://${credential:mcp_host}:${credential:mcp_port}/mcp"
        TOML
      end

      it "interpolates all placeholders in one string" do
        allow(Mcp::Secrets).to receive(:get).with("mcp_host").and_return("api.example.com")
        allow(Mcp::Secrets).to receive(:get).with("mcp_port").and_return("8443")

        servers = config.http_servers

        expect(servers.first[:url]).to eq("https://api.example.com:8443/mcp")
      end
    end

    context "with server missing url" do
      before do
        File.write(config_path, <<~TOML)
          [servers.incomplete]
          transport = "http"
        TOML
      end

      it "skips servers without a url and collects a warning" do
        expect(config.http_servers).to eq([])
        expect(config.warnings).to include(match(/incomplete.*no url/))
      end
    end

    context "with mixed valid and invalid entries" do
      before do
        File.write(config_path, <<~TOML)
          [servers.valid]
          transport = "http"
          url = "http://localhost:3000/mcp"

          [servers.no_transport]
          url = "http://localhost:4000/mcp"

          [servers.wrong_transport]
          transport = "stdio"
          command = "some-command"
        TOML
      end

      it "returns only valid HTTP servers" do
        servers = config.http_servers

        expect(servers.size).to eq(1)
        expect(servers.first[:name]).to eq("valid")
      end
    end
  end

  describe "#stdio_servers" do
    context "when config file does not exist" do
      let(:config_path) { File.join(config_dir, "nonexistent.toml") }

      it "returns an empty array" do
        expect(config.stdio_servers).to eq([])
      end
    end

    context "with stdio server entries" do
      before do
        File.write(config_path, <<~TOML)
          [servers.filesystem]
          transport = "stdio"
          command = "mcp-server-filesystem"
          args = ["--root", "/workspace"]
          env = { DEBUG = "true" }

          [servers.linear_toon]
          transport = "stdio"
          command = "linear-toon-mcp"
        TOML
      end

      it "returns all stdio server configs" do
        expect(config.stdio_servers.size).to eq(2)
      end

      it "parses command, args, and env" do
        fs = config.stdio_servers.find { |s| s[:name] == "filesystem" }

        expect(fs[:command]).to eq("mcp-server-filesystem")
        expect(fs[:args]).to eq(["--root", "/workspace"])
        expect(fs[:env]).to eq({"DEBUG" => "true"})
      end

      it "defaults args to empty array and env to empty hash" do
        lt = config.stdio_servers.find { |s| s[:name] == "linear_toon" }

        expect(lt[:args]).to eq([])
        expect(lt[:env]).to eq({})
      end
    end

    context "with non-stdio transports" do
      before do
        File.write(config_path, <<~TOML)
          [servers.web_api]
          transport = "http"
          url = "http://localhost:8080/mcp"

          [servers.local_tool]
          transport = "stdio"
          command = "my-tool"
        TOML
      end

      it "skips non-stdio servers silently" do
        servers = config.stdio_servers

        expect(servers.size).to eq(1)
        expect(servers.first[:name]).to eq("local_tool")
      end
    end

    context "with credential interpolation" do
      before do
        File.write(config_path, <<~TOML)
          [servers.tool]
          transport = "stdio"
          command = "${credential:tool_path}/my-tool"
          args = ["--config", "${credential:config_dir}/config.yml"]
          env = { API_KEY = "${credential:api_key}" }
        TOML
      end

      it "interpolates credentials in command, args, and env values" do
        allow(Mcp::Secrets).to receive(:get).with("tool_path").and_return("/usr/local/bin")
        allow(Mcp::Secrets).to receive(:get).with("config_dir").and_return("/etc/my-tool")
        allow(Mcp::Secrets).to receive(:get).with("api_key").and_return("secret-abc")

        server = config.stdio_servers.first

        expect(server[:command]).to eq("/usr/local/bin/my-tool")
        expect(server[:args]).to eq(["--config", "/etc/my-tool/config.yml"])
        expect(server[:env]).to eq({"API_KEY" => "secret-abc"})
      end

      it "skips servers with missing credentials and collects a warning" do
        allow(Mcp::Secrets).to receive(:get).and_return(nil)

        expect(config.stdio_servers).to eq([])
        expect(config.warnings).to include(match(/tool.*missing credential.*tool_path/))
      end
    end

    context "with server missing command" do
      before do
        File.write(config_path, <<~TOML)
          [servers.incomplete]
          transport = "stdio"
        TOML
      end

      it "skips servers without a command and collects a warning" do
        expect(config.stdio_servers).to eq([])
        expect(config.warnings).to include(match(/incomplete.*no command/))
      end
    end
  end

  describe "#all_servers" do
    context "when config file does not exist" do
      let(:config_path) { File.join(config_dir, "nonexistent.toml") }

      it "returns an empty array" do
        expect(config.all_servers).to eq([])
      end
    end

    context "with mixed servers" do
      before do
        File.write(config_path, <<~TOML)
          [servers.web]
          transport = "http"
          url = "http://localhost:3000/mcp"

          [servers.tool]
          transport = "stdio"
          command = "my-tool"
          args = ["--verbose"]
        TOML
      end

      it "returns all servers with raw settings and injected name" do
        servers = config.all_servers

        expect(servers.size).to eq(2)

        web = servers.find { |s| s["name"] == "web" }
        expect(web["transport"]).to eq("http")
        expect(web["url"]).to eq("http://localhost:3000/mcp")

        tool = servers.find { |s| s["name"] == "tool" }
        expect(tool["transport"]).to eq("stdio")
        expect(tool["command"]).to eq("my-tool")
        expect(tool["args"]).to eq(["--verbose"])
      end

      it "does not interpolate credential placeholders" do
        File.write(config_path, <<~TOML)
          [servers.api]
          transport = "http"
          url = "https://${credential:some_host}/mcp"
        TOML

        servers = config.all_servers
        expect(servers.first["url"]).to eq("https://${credential:some_host}/mcp")
      end
    end
  end

  describe "#add_server" do
    it "creates a new server entry" do
      config.add_server("sentry", {"transport" => "http", "url" => "https://mcp.sentry.dev/mcp"})

      servers = config.all_servers
      expect(servers.size).to eq(1)
      expect(servers.first).to include("name" => "sentry", "url" => "https://mcp.sentry.dev/mcp")
    end

    it "preserves existing servers" do
      File.write(config_path, <<~TOML)
        [servers.existing]
        transport = "http"
        url = "http://localhost:3000/mcp"
      TOML

      config.add_server("new_one", {"transport" => "http", "url" => "http://new.test/mcp"})

      servers = config.all_servers
      expect(servers.size).to eq(2)
      names = servers.map { |s| s["name"] }
      expect(names).to contain_exactly("existing", "new_one")
    end

    it "creates the config file and directories if missing" do
      nested_path = File.join(config_dir, "nested", "dir", "mcp.toml")
      nested_config = described_class.new(path: nested_path)

      nested_config.add_server("test", {"transport" => "http", "url" => "http://test/mcp"})

      expect(File.exist?(nested_path)).to be true
    end

    it "raises ArgumentError for duplicate server names" do
      config.add_server("sentry", {"transport" => "http", "url" => "http://test/mcp"})

      expect {
        config.add_server("sentry", {"transport" => "http", "url" => "http://other/mcp"})
      }.to raise_error(ArgumentError, /already exists/)
    end

    it "raises ArgumentError for invalid names" do
      expect {
        config.add_server("my server", {"transport" => "http", "url" => "http://test/mcp"})
      }.to raise_error(ArgumentError, /invalid server name/)
    end

    it "accepts hyphens and underscores in names" do
      expect {
        config.add_server("my-server_1", {"transport" => "http", "url" => "http://test/mcp"})
      }.not_to raise_error
    end

    it "writes valid TOML that can be re-read for stdio servers" do
      config.add_server("fs", {
        "transport" => "stdio",
        "command" => "mcp-server-filesystem",
        "args" => ["--root", "/workspace"],
        "env" => {"DEBUG" => "true"}
      })

      reloaded = described_class.new(path: config_path)
      server = reloaded.stdio_servers.first

      expect(server[:name]).to eq("fs")
      expect(server[:command]).to eq("mcp-server-filesystem")
      expect(server[:args]).to eq(["--root", "/workspace"])
      expect(server[:env]).to eq({"DEBUG" => "true"})
    end

    it "writes valid TOML that can be re-read for HTTP servers with headers" do
      config.add_server("api", {
        "transport" => "http",
        "url" => "https://api.test/mcp",
        "headers" => {"Authorization" => "Bearer token", "X-Custom" => "value"}
      })

      reloaded = described_class.new(path: config_path)
      server = reloaded.http_servers.first

      expect(server[:name]).to eq("api")
      expect(server[:url]).to eq("https://api.test/mcp")
      expect(server[:headers]).to eq({"Authorization" => "Bearer token", "X-Custom" => "value"})
    end

    it "sets restrictive file permissions on write" do
      config.add_server("test", {"transport" => "http", "url" => "http://test/mcp"})

      mode = File.stat(config_path).mode & 0o777
      expect(mode).to eq(0o600)
    end
  end

  describe "#remove_server" do
    before do
      File.write(config_path, <<~TOML)
        [servers.alpha]
        transport = "http"
        url = "http://alpha.test/mcp"

        [servers.beta]
        transport = "stdio"
        command = "beta-tool"
      TOML
    end

    it "removes the named server" do
      config.remove_server("alpha")

      servers = config.all_servers
      expect(servers.size).to eq(1)
      expect(servers.first["name"]).to eq("beta")
    end

    it "preserves remaining servers" do
      config.remove_server("alpha")

      reloaded = described_class.new(path: config_path)
      server = reloaded.stdio_servers.first
      expect(server[:name]).to eq("beta")
      expect(server[:command]).to eq("beta-tool")
    end

    it "raises ArgumentError when server not found" do
      expect {
        config.remove_server("ghost")
      }.to raise_error(ArgumentError, /not found/)
    end

    context "when config file does not exist" do
      let(:config_path) { File.join(config_dir, "nonexistent.toml") }

      it "raises ArgumentError" do
        expect {
          config.remove_server("anything")
        }.to raise_error(ArgumentError, /not found/)
      end
    end
  end

  describe "logger injection" do
    let(:logger) { instance_double("Logger") }

    subject(:config) { described_class.new(path: config_path, logger: logger) }

    before do
      File.write(config_path, <<~TOML)
        [servers.broken]
        transport = "http"
      TOML
    end

    it "logs warnings through the injected logger" do
      expect(logger).to receive(:warn).with(/broken.*no url/)

      config.http_servers
    end

    it "does not log when no logger provided" do
      quiet_config = described_class.new(path: config_path)

      expect { quiet_config.http_servers }.not_to raise_error
      expect(quiet_config.warnings).to include(match(/broken.*no url/))
    end
  end
end
