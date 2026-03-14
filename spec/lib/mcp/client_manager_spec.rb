# frozen_string_literal: true

require "rails_helper"

RSpec.describe Mcp::ClientManager do
  let(:config) { instance_double(Mcp::Config) }

  subject(:manager) { described_class.new(config: config) }

  describe "#register_tools" do
    let(:registry) { Tools::Registry.new }

    context "with no configured servers" do
      before { allow(config).to receive(:http_servers).and_return([]) }

      it "registers no additional tools" do
        manager.register_tools(registry)

        expect(registry.any?).to be false
      end
    end

    context "with a configured HTTP server" do
      let(:mcp_tool) do
        MCP::Client::Tool.new(
          name: "create_image",
          description: "Generate an image",
          input_schema: {"type" => "object", "properties" => {}}
        )
      end

      let(:mcp_client) { instance_double(MCP::Client, tools: [mcp_tool]) }
      let(:transport) { instance_double(MCP::Client::HTTP) }

      before do
        allow(config).to receive(:http_servers).and_return([
          {name: "mythonix", url: "http://localhost:3000/mcp/v2", headers: {}}
        ])
        allow(MCP::Client::HTTP).to receive(:new).and_return(transport)
        allow(MCP::Client).to receive(:new).and_return(mcp_client)
      end

      it "registers MCP tools with namespaced names" do
        manager.register_tools(registry)

        expect(registry.registered?("mythonix__create_image")).to be true
      end

      it "creates HTTP transport with server url and headers" do
        manager.register_tools(registry)

        expect(MCP::Client::HTTP).to have_received(:new).with(
          url: "http://localhost:3000/mcp/v2",
          headers: {}
        )
      end

      it "creates MCP client with the transport" do
        manager.register_tools(registry)

        expect(MCP::Client).to have_received(:new).with(transport: transport)
      end

      it "produces valid schemas for the Anthropic API" do
        manager.register_tools(registry)

        schema = registry.schemas.first
        expect(schema).to include(
          name: "mythonix__create_image",
          description: "Generate an image"
        )
        expect(schema[:input_schema]).to be_a(Hash)
      end
    end

    context "with multiple servers" do
      let(:tool_a) do
        MCP::Client::Tool.new(name: "tool_a", description: "Tool A", input_schema: {})
      end

      let(:tool_b) do
        MCP::Client::Tool.new(name: "tool_b", description: "Tool B", input_schema: {})
      end

      let(:client_a) { instance_double(MCP::Client, tools: [tool_a]) }
      let(:client_b) { instance_double(MCP::Client, tools: [tool_b]) }

      before do
        allow(config).to receive(:http_servers).and_return([
          {name: "server_a", url: "http://a.test/mcp", headers: {}},
          {name: "server_b", url: "http://b.test/mcp", headers: {}}
        ])
        allow(MCP::Client::HTTP).to receive(:new)
          .and_return(instance_double(MCP::Client::HTTP))
        allow(MCP::Client).to receive(:new).and_return(client_a, client_b)
      end

      it "registers tools from all servers with proper namespacing" do
        manager.register_tools(registry)

        expect(registry.registered?("server_a__tool_a")).to be true
        expect(registry.registered?("server_b__tool_b")).to be true
      end

      it "keeps tools from different servers isolated" do
        manager.register_tools(registry)

        expect(registry.schemas.size).to eq(2)
      end
    end

    context "when a server connection fails" do
      let(:working_tool) do
        MCP::Client::Tool.new(name: "working_tool", description: "Works", input_schema: {})
      end

      before do
        allow(config).to receive(:http_servers).and_return([
          {name: "broken", url: "http://broken.test/mcp", headers: {}},
          {name: "working", url: "http://working.test/mcp", headers: {}}
        ])

        broken_client = instance_double(MCP::Client)
        allow(broken_client).to receive(:tools)
          .and_raise(MCP::Client::RequestHandlerError.new(
            "Connection refused", {method: "tools/list"}
          ))

        working_client = instance_double(MCP::Client, tools: [working_tool])

        allow(MCP::Client::HTTP).to receive(:new)
          .and_return(instance_double(MCP::Client::HTTP))
        allow(MCP::Client).to receive(:new)
          .and_return(broken_client, working_client)
      end

      it "logs a warning for the failed server" do
        expect(Rails.logger).to receive(:warn).with(/broken.*Connection refused/)
        allow(Rails.logger).to receive(:info)

        manager.register_tools(registry)
      end

      it "continues registering tools from remaining servers" do
        allow(Rails.logger).to receive(:warn)
        allow(Rails.logger).to receive(:info)

        manager.register_tools(registry)

        expect(registry.registered?("working__working_tool")).to be true
      end
    end

    context "when server returns no tools" do
      before do
        allow(config).to receive(:http_servers).and_return([
          {name: "empty", url: "http://empty.test/mcp", headers: {}}
        ])
        allow(MCP::Client::HTTP).to receive(:new)
          .and_return(instance_double(MCP::Client::HTTP))
        allow(MCP::Client).to receive(:new)
          .and_return(instance_double(MCP::Client, tools: []))
      end

      it "registers no tools without error" do
        allow(Rails.logger).to receive(:info)

        manager.register_tools(registry)

        expect(registry.any?).to be false
      end
    end
  end
end
