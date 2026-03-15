# frozen_string_literal: true

require "rails_helper"
require "mcp"

RSpec.describe Mcp::HealthCheck do
  describe ".call" do
    context "with an HTTP server" do
      let(:server) do
        {name: "sentry", transport: "http", url: "https://mcp.sentry.dev/mcp", headers: {}}
      end

      it "returns connected with tool count on success" do
        tool = instance_double("MCP::Client::Tool")
        client = instance_double(MCP::Client, tools: [tool, tool, tool])
        transport = instance_double(MCP::Client::HTTP)

        allow(MCP::Client::HTTP).to receive(:new)
          .with(url: "https://mcp.sentry.dev/mcp", headers: {})
          .and_return(transport)
        allow(MCP::Client).to receive(:new)
          .with(transport: transport)
          .and_return(client)

        result = described_class.call(server)

        expect(result).to eq(status: :connected, tools: 3)
      end

      it "returns failed on connection error" do
        transport = instance_double(MCP::Client::HTTP)
        allow(MCP::Client::HTTP).to receive(:new).and_return(transport)

        client = instance_double(MCP::Client)
        allow(MCP::Client).to receive(:new).and_return(client)
        allow(client).to receive(:tools).and_raise(
          MCP::Client::RequestHandlerError.new("Connection refused", {method: "tools/list"})
        )

        result = described_class.call(server)

        expect(result[:status]).to eq(:failed)
        expect(result[:error]).to include("Connection refused")
      end

      it "returns failed on timeout" do
        allow(Timeout).to receive(:timeout).and_raise(Timeout::Error)

        result = described_class.call(server)

        expect(result).to eq(status: :failed, error: "connection timeout")
      end
    end

    context "with a stdio server" do
      let(:server) do
        {name: "fs", transport: "stdio", command: "mcp-server-fs", args: ["--root", "/"], env: {}}
      end

      it "returns connected with tool count and shuts down transport" do
        tool = instance_double("MCP::Client::Tool")
        client = instance_double(MCP::Client, tools: [tool])
        transport = instance_double(Mcp::StdioTransport, shutdown: nil)

        allow(Mcp::StdioTransport).to receive(:new)
          .with(command: "mcp-server-fs", args: ["--root", "/"], env: {})
          .and_return(transport)
        allow(MCP::Client).to receive(:new)
          .with(transport: transport)
          .and_return(client)

        result = described_class.call(server)

        expect(result).to eq(status: :connected, tools: 1)
        expect(transport).to have_received(:shutdown)
      end

      it "shuts down transport even when tools call fails" do
        transport = instance_double(Mcp::StdioTransport, shutdown: nil)
        allow(Mcp::StdioTransport).to receive(:new).and_return(transport)

        client = instance_double(MCP::Client)
        allow(MCP::Client).to receive(:new).and_return(client)
        allow(client).to receive(:tools).and_raise(Errno::EPIPE)

        result = described_class.call(server)

        expect(result[:status]).to eq(:failed)
        expect(transport).to have_received(:shutdown)
      end
    end

    context "with unknown transport" do
      it "returns failed" do
        result = described_class.call(name: "mystery", transport: "grpc")

        expect(result).to eq(status: :failed, error: "unknown transport 'grpc'")
      end
    end
  end
end
