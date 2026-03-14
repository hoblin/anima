# frozen_string_literal: true

require "rails_helper"
require "mcp"
require "faraday"

RSpec.describe Tools::McpTool do
  let(:mcp_tool) do
    MCP::Client::Tool.new(
      name: "create_image",
      description: "Generate an image from a text prompt",
      input_schema: {
        "type" => "object",
        "properties" => {
          "prompt" => {"type" => "string", "description" => "Image description"}
        },
        "required" => ["prompt"]
      }
    )
  end

  let(:mcp_client) { instance_double(MCP::Client) }

  subject(:tool) do
    described_class.new(
      server_name: "mythonix",
      mcp_client: mcp_client,
      mcp_tool: mcp_tool
    )
  end

  describe "#tool_name" do
    it "returns namespaced name as server__tool" do
      expect(tool.tool_name).to eq("mythonix__create_image")
    end
  end

  describe "#description" do
    it "delegates to the MCP tool" do
      expect(tool.description).to eq("Generate an image from a text prompt")
    end
  end

  describe "#input_schema" do
    it "delegates to the MCP tool" do
      expect(tool.input_schema).to eq(mcp_tool.input_schema)
    end
  end

  describe "#schema" do
    it "builds Anthropic-compatible schema hash" do
      expect(tool.schema).to eq({
        name: "mythonix__create_image",
        description: "Generate an image from a text prompt",
        input_schema: mcp_tool.input_schema
      })
    end
  end

  describe "#new" do
    it "returns self since MCP tools are stateless wrappers" do
      expect(tool.new(shell_session: double, session: double)).to be(tool)
    end
  end

  describe "#execute" do
    context "with successful text response" do
      before do
        allow(mcp_client).to receive(:call_tool).and_return({
          "result" => {
            "content" => [
              {"type" => "text", "text" => "Image created at /path/to/image.png"}
            ]
          }
        })
      end

      it "returns the text content" do
        result = tool.execute({"prompt" => "a red dragon"})

        expect(result).to eq("Image created at /path/to/image.png")
      end

      it "passes the MCP tool object and arguments to the client" do
        tool.execute({"prompt" => "a red dragon"})

        expect(mcp_client).to have_received(:call_tool).with(
          tool: mcp_tool,
          arguments: {"prompt" => "a red dragon"}
        )
      end
    end

    context "with multiple content blocks" do
      before do
        allow(mcp_client).to receive(:call_tool).and_return({
          "result" => {
            "content" => [
              {"type" => "text", "text" => "Line 1"},
              {"type" => "text", "text" => "Line 2"}
            ]
          }
        })
      end

      it "joins text blocks with newlines" do
        result = tool.execute({})

        expect(result).to eq("Line 1\nLine 2")
      end
    end

    context "with image content blocks" do
      before do
        allow(mcp_client).to receive(:call_tool).and_return({
          "result" => {
            "content" => [
              {"type" => "text", "text" => "Generated image:"},
              {"type" => "image", "mimeType" => "image/png", "data" => "base64..."}
            ]
          }
        })
      end

      it "includes image type placeholder" do
        result = tool.execute({})

        expect(result).to include("[image: image/png]")
        expect(result).to include("Generated image:")
      end
    end

    context "with MCP error response (isError flag)" do
      before do
        allow(mcp_client).to receive(:call_tool).and_return({
          "result" => {
            "isError" => true,
            "content" => [
              {"type" => "text", "text" => "Invalid prompt parameter"}
            ]
          }
        })
      end

      it "returns an error hash with the tool name" do
        result = tool.execute({"prompt" => ""})

        expect(result).to be_a(Hash)
        expect(result[:error]).to include("Invalid prompt parameter")
        expect(result[:error]).to include("mythonix__create_image")
      end
    end

    context "when MCP client raises an exception" do
      before do
        allow(mcp_client).to receive(:call_tool)
          .and_raise(MCP::Client::RequestHandlerError.new(
            "Connection refused", {method: "tools/call"}
          ))
      end

      it "returns an error hash without raising" do
        result = tool.execute({"prompt" => "test"})

        expect(result).to be_a(Hash)
        expect(result[:error]).to include("Connection refused")
        expect(result[:error]).to include("mythonix__create_image")
      end
    end

    context "when a network error occurs" do
      before do
        allow(mcp_client).to receive(:call_tool)
          .and_raise(Faraday::ConnectionFailed, "Connection refused")
      end

      it "returns an error hash" do
        result = tool.execute({"prompt" => "test"})

        expect(result).to be_a(Hash)
        expect(result[:error]).to include("mythonix__create_image")
      end
    end
  end

  describe "Registry compatibility" do
    it "can be registered and looked up by name" do
      registry = Tools::Registry.new
      registry.register(tool)

      expect(registry.registered?("mythonix__create_image")).to be true
    end

    it "appears in registry schemas" do
      registry = Tools::Registry.new
      registry.register(tool)

      schemas = registry.schemas
      expect(schemas.size).to eq(1)
      expect(schemas.first[:name]).to eq("mythonix__create_image")
      expect(schemas.first[:description]).to eq("Generate an image from a text prompt")
    end

    it "can be executed through the registry" do
      allow(mcp_client).to receive(:call_tool).and_return({
        "result" => {
          "content" => [{"type" => "text", "text" => "ok"}]
        }
      })

      registry = Tools::Registry.new
      registry.register(tool)

      result = registry.execute("mythonix__create_image", {"prompt" => "test"})
      expect(result).to eq("ok")
    end

    it "coexists with built-in tools" do
      allow(mcp_client).to receive(:call_tool).and_return({
        "result" => {"content" => [{"type" => "text", "text" => "mcp result"}]}
      })

      registry = Tools::Registry.new
      registry.register(Tools::WebGet)
      registry.register(tool)

      expect(registry.registered?("web_get")).to be true
      expect(registry.registered?("mythonix__create_image")).to be true
      expect(registry.schemas.size).to eq(2)
    end
  end
end
