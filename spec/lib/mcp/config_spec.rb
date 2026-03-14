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

    context "with environment variable interpolation" do
      before do
        File.write(config_path, <<~TOML)
          [servers.api]
          transport = "http"
          url = "https://${TEST_MCP_HOST}/mcp"
          headers = { Authorization = "Bearer ${TEST_MCP_TOKEN}" }
        TOML
      end

      it "replaces ${VAR} placeholders in urls" do
        ENV["TEST_MCP_HOST"] = "api.example.com"
        ENV["TEST_MCP_TOKEN"] = "secret-123"

        servers = config.http_servers

        expect(servers.first[:url]).to eq("https://api.example.com/mcp")
      ensure
        ENV.delete("TEST_MCP_HOST")
        ENV.delete("TEST_MCP_TOKEN")
      end

      it "replaces ${VAR} placeholders in headers" do
        ENV["TEST_MCP_HOST"] = "api.example.com"
        ENV["TEST_MCP_TOKEN"] = "secret-123"

        servers = config.http_servers

        expect(servers.first[:headers]["Authorization"]).to eq("Bearer secret-123")
      ensure
        ENV.delete("TEST_MCP_HOST")
        ENV.delete("TEST_MCP_TOKEN")
      end

      it "raises KeyError for missing environment variables" do
        ENV.delete("TEST_MCP_HOST")
        ENV.delete("TEST_MCP_TOKEN")

        expect { config.http_servers }.to raise_error(KeyError, /TEST_MCP_HOST/)
      end
    end

    context "with server missing url" do
      before do
        File.write(config_path, <<~TOML)
          [servers.incomplete]
          transport = "http"
        TOML
      end

      it "skips servers without a url and logs a warning" do
        expect(Rails.logger).to receive(:warn).with(/incomplete.*no url/)

        expect(config.http_servers).to eq([])
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

    context "with environment variable interpolation" do
      before do
        File.write(config_path, <<~TOML)
          [servers.tool]
          transport = "stdio"
          command = "${TEST_TOOL_PATH}/my-tool"
          args = ["--config", "${TEST_CONFIG_DIR}/config.yml"]
          env = { API_KEY = "${TEST_API_KEY}" }
        TOML
      end

      it "interpolates env vars in command, args, and env values" do
        ENV["TEST_TOOL_PATH"] = "/usr/local/bin"
        ENV["TEST_CONFIG_DIR"] = "/etc/my-tool"
        ENV["TEST_API_KEY"] = "secret-abc"

        server = config.stdio_servers.first

        expect(server[:command]).to eq("/usr/local/bin/my-tool")
        expect(server[:args]).to eq(["--config", "/etc/my-tool/config.yml"])
        expect(server[:env]).to eq({"API_KEY" => "secret-abc"})
      ensure
        ENV.delete("TEST_TOOL_PATH")
        ENV.delete("TEST_CONFIG_DIR")
        ENV.delete("TEST_API_KEY")
      end

      it "raises KeyError for missing environment variables" do
        ENV.delete("TEST_TOOL_PATH")

        expect { config.stdio_servers }.to raise_error(KeyError, /TEST_TOOL_PATH/)
      end
    end

    context "with server missing command" do
      before do
        File.write(config_path, <<~TOML)
          [servers.incomplete]
          transport = "stdio"
        TOML
      end

      it "skips servers without a command and logs a warning" do
        expect(Rails.logger).to receive(:warn).with(/incomplete.*no command/)

        expect(config.stdio_servers).to eq([])
      end
    end
  end
end
