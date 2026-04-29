# frozen_string_literal: true

require "rails_helper"

RSpec.describe Mcp::ClientManager do
  let(:config) { instance_double(Mcp::Config) }

  subject(:manager) { described_class.new(config: config) }

  before do
    allow(config).to receive(:http_servers).and_return([])
    allow(config).to receive(:stdio_servers).and_return([])
    allow(config).to receive(:warnings).and_return([])
  end

  describe "#register_tools" do
    let(:registry) { Tools::Registry.new }

    context "with no configured servers" do
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

    context "with a configured stdio server" do
      let(:mcp_tool) do
        MCP::Client::Tool.new(
          name: "list_issues",
          description: "List Linear issues",
          input_schema: {"type" => "object", "properties" => {}}
        )
      end

      let(:mcp_client) { instance_double(MCP::Client, tools: [mcp_tool]) }
      let(:transport) { instance_double(Mcp::StdioTransport) }

      before do
        allow(config).to receive(:stdio_servers).and_return([
          {name: "linear_toon", command: "linear-toon-mcp", args: [], env: {}}
        ])
        allow(Mcp::StdioTransport).to receive(:new).and_return(transport)
        allow(MCP::Client).to receive(:new).and_return(mcp_client)
      end

      it "registers MCP tools with namespaced names" do
        manager.register_tools(registry)

        expect(registry.registered?("linear_toon__list_issues")).to be true
      end

      it "creates stdio transport with command, args, and env" do
        manager.register_tools(registry)

        expect(Mcp::StdioTransport).to have_received(:new).with(
          command: "linear-toon-mcp",
          args: [],
          env: {}
        )
      end

      it "creates MCP client with the stdio transport" do
        manager.register_tools(registry)

        expect(MCP::Client).to have_received(:new).with(transport: transport)
      end
    end

    context "with multiple servers across transports" do
      let(:http_tool) do
        MCP::Client::Tool.new(name: "http_tool", description: "HTTP tool", input_schema: {})
      end

      let(:stdio_tool) do
        MCP::Client::Tool.new(name: "stdio_tool", description: "Stdio tool", input_schema: {})
      end

      let(:http_client) { instance_double(MCP::Client, tools: [http_tool]) }
      let(:stdio_client) { instance_double(MCP::Client, tools: [stdio_tool]) }

      before do
        allow(config).to receive(:http_servers).and_return([
          {name: "web_server", url: "http://web.test/mcp", headers: {}}
        ])
        allow(config).to receive(:stdio_servers).and_return([
          {name: "local_server", command: "local-mcp", args: [], env: {}}
        ])
        allow(MCP::Client::HTTP).to receive(:new)
          .and_return(instance_double(MCP::Client::HTTP))
        allow(Mcp::StdioTransport).to receive(:new)
          .and_return(instance_double(Mcp::StdioTransport))
        allow(MCP::Client).to receive(:new).and_return(http_client, stdio_client)
      end

      it "registers tools from both HTTP and stdio servers" do
        manager.register_tools(registry)

        expect(registry.registered?("web_server__http_tool")).to be true
        expect(registry.registered?("local_server__stdio_tool")).to be true
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

      it "returns the warning so the caller can surface it" do
        allow(Rails.logger).to receive(:warn)
        allow(Rails.logger).to receive(:info)

        warnings = manager.register_tools(registry)

        expect(warnings).to include(match(/broken.*Connection refused/))
      end

      it "continues registering tools from remaining servers" do
        allow(Rails.logger).to receive(:warn)
        allow(Rails.logger).to receive(:info)

        manager.register_tools(registry)

        expect(registry.registered?("working__working_tool")).to be true
      end
    end

    context "when a stdio server fails to spawn" do
      let(:working_tool) do
        MCP::Client::Tool.new(name: "works", description: "Works", input_schema: {})
      end

      before do
        allow(config).to receive(:stdio_servers).and_return([
          {name: "bad_cmd", command: "nonexistent", args: [], env: {}},
          {name: "good_cmd", command: "echo", args: [], env: {}}
        ])

        broken_transport = Mcp::StdioTransport.new(command: "nonexistent", args: [], env: {})
        allow(Mcp::StdioTransport).to receive(:new)
          .and_return(broken_transport, instance_double(Mcp::StdioTransport))

        broken_client = MCP::Client.new(transport: broken_transport)
        working_client = instance_double(MCP::Client, tools: [working_tool])

        allow(MCP::Client).to receive(:new).and_return(broken_client, working_client)
      end

      it "logs a warning and continues to the next server" do
        expect(Rails.logger).to receive(:warn).with(/bad_cmd/)
        allow(Rails.logger).to receive(:info)

        manager.register_tools(registry)

        expect(registry.registered?("good_cmd__works")).to be true
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

    # Regression coverage for issue #469: every Tools::Registry.build used
    # to construct a fresh manager, which spawned a fresh stdio process per
    # job. The shared singleton now caches connections across registry
    # builds — so calling register_tools twice must reuse, not respawn.
    context "when called multiple times against the same manager" do
      let(:mcp_tool) do
        MCP::Client::Tool.new(name: "search", description: "Search", input_schema: {})
      end
      let(:mcp_client) { instance_double(MCP::Client, tools: [mcp_tool]) }

      before do
        allow(config).to receive(:stdio_servers).and_return([
          {name: "brave-search", command: "npx", args: [], env: {}}
        ])
        allow(Mcp::StdioTransport).to receive(:new).and_return(instance_double(Mcp::StdioTransport))
        allow(MCP::Client).to receive(:new).and_return(mcp_client)
        allow(Rails.logger).to receive(:info)
      end

      it "spawns each transport exactly once across repeated register_tools calls" do
        manager.register_tools(Tools::Registry.new)
        manager.register_tools(Tools::Registry.new)
        manager.register_tools(Tools::Registry.new)

        expect(Mcp::StdioTransport).to have_received(:new).once
        expect(MCP::Client).to have_received(:new).once
      end

      it "fetches the tool catalog from each server only once" do
        manager.register_tools(Tools::Registry.new)
        manager.register_tools(Tools::Registry.new)

        expect(mcp_client).to have_received(:tools).once
      end

      it "still attaches cached tools to every registry it is given" do
        registry_a = Tools::Registry.new
        registry_b = Tools::Registry.new

        manager.register_tools(registry_a)
        manager.register_tools(registry_b)

        expect(registry_a.registered?("brave-search__search")).to be true
        expect(registry_b.registered?("brave-search__search")).to be true
      end

      it "returns load warnings only on the first call" do
        allow(config).to receive(:warnings).and_return(["config-level warning"])

        first = manager.register_tools(Tools::Registry.new)
        second = manager.register_tools(Tools::Registry.new)

        expect(first).to include("config-level warning")
        expect(second).to eq([])
      end
    end
  end

  describe ".shared" do
    after { described_class.reset! }

    it "returns the same instance across calls" do
      expect(described_class.shared).to be(described_class.shared)
    end

    it "rebuilds the instance after .reset!" do
      original = described_class.shared
      described_class.reset!

      expect(described_class.shared).not_to be(original)
    end
  end

  describe "#shutdown" do
    let(:registry) { Tools::Registry.new }
    let(:transport) { instance_double(Mcp::StdioTransport, shutdown: nil) }
    let(:mcp_tool) do
      MCP::Client::Tool.new(name: "search", description: "Search", input_schema: {})
    end
    let(:mcp_client) { instance_double(MCP::Client, tools: [mcp_tool]) }

    before do
      allow(config).to receive(:stdio_servers).and_return([
        {name: "brave-search", command: "npx", args: [], env: {}}
      ])
      allow(Mcp::StdioTransport).to receive(:new).and_return(transport)
      allow(MCP::Client).to receive(:new).and_return(mcp_client)
      allow(Rails.logger).to receive(:info)
    end

    it "shuts down each cached transport so spawned subprocesses are reaped" do
      manager.register_tools(registry)
      manager.shutdown

      expect(transport).to have_received(:shutdown)
    end

    it "rebuilds the cache on the next register_tools call" do
      manager.register_tools(registry)
      manager.shutdown
      manager.register_tools(Tools::Registry.new)

      expect(Mcp::StdioTransport).to have_received(:new).twice
    end

    it "is safe to call without prior register_tools" do
      expect { manager.shutdown }.not_to raise_error
    end
  end
end
