# frozen_string_literal: true

module Tools
  # Wraps a single MCP server tool for use with {Tools::Registry}.
  # Responds to the same duck-typed interface as {Tools::Base} subclasses,
  # allowing the Registry to treat MCP tools identically to built-in tools.
  #
  # Tool names are namespaced as `<server_name>__<tool_name>` to prevent
  # collisions between servers and with built-in tools.
  #
  # @example
  #   wrapper = Tools::McpTool.new(
  #     server_name: "mythonix",
  #     mcp_client: client,
  #     mcp_tool: client.tools.first
  #   )
  #   wrapper.tool_name  # => "mythonix__create_image"
  #   wrapper.execute({"prompt" => "a red dragon"})
  class McpTool
    # @return [String] namespaced tool identifier (<server>__<tool>)
    attr_reader :tool_name

    # @param server_name [String] MCP server name from config
    # @param mcp_client [MCP::Client] the client instance for this server
    # @param mcp_tool [MCP::Client::Tool] tool metadata from the server
    def initialize(server_name:, mcp_client:, mcp_tool:)
      @tool_name = "#{server_name}__#{mcp_tool.name}"
      @mcp_client = mcp_client
      @mcp_tool = mcp_tool
    end

    # @return [String] tool description from the MCP server
    def description
      @mcp_tool.description
    end

    # @return [Hash] JSON Schema for tool input parameters
    def input_schema
      @mcp_tool.input_schema
    end

    # Builds the schema hash expected by the Anthropic tools API.
    # @return [Hash] with :name, :description, and :input_schema keys
    def schema
      {name: tool_name, description: description, input_schema: input_schema}
    end

    # Returns self — MCP tools are stateless wrappers that don't need
    # session context. This allows {Tools::Registry#execute} to call
    # `.new(**context).execute(input)` without modification.
    #
    # @return [self]
    def new(**)
      self
    end

    # Calls the MCP server tool and normalizes the response.
    #
    # @param input [Hash] tool input parameters from the LLM
    # @return [String] normalized tool output
    # @return [Hash] with :error key on failure
    def execute(input)
      response = @mcp_client.call_tool(tool: @mcp_tool, arguments: input)
      normalize_response(response)
    rescue => error
      {error: "#{tool_name}: #{error.message}"}
    end

    private

    # Extracts content from an MCP tool response (JSON-RPC envelope).
    # Checks the `isError` flag and routes accordingly.
    #
    # @param response [Hash] full JSON-RPC response from MCP client
    # @return [String] concatenated text content
    # @return [Hash] with :error key if the response indicates an error
    def normalize_response(response)
      result = response["result"] || response
      error = result["isError"]

      text = extract_text(result)
      error ? {error: "#{tool_name}: #{text}"} : text
    end

    # Extracts human-readable text from MCP content blocks.
    # MCP responses contain an array of typed content blocks.
    #
    # @param result [Hash] MCP result containing "content" array
    # @return [String] concatenated text from all content blocks
    def extract_text(result)
      content = result["content"]

      return result.to_json unless content

      case content
      when Array
        content.filter_map { |block|
          case block["type"]
          when "text" then block["text"]
          when "image" then "[image: #{block["mimeType"]}]"
          else block.to_json
          end
        }.join("\n")
      when String
        content
      else
        content.to_json
      end
    end
  end
end
