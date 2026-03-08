# frozen_string_literal: true

module Tools
  class UnknownToolError < StandardError; end

  # Manages tool registration, schema export, and dispatch.
  # Tools are registered by class and looked up by name at execution time.
  #
  # @example
  #   registry = Tools::Registry.new
  #   registry.register(Tools::WebGet)
  #   registry.schemas      # => [{name: "web_get", description: "...", input_schema: {...}}]
  #   registry.execute("web_get", {"url" => "https://example.com"})
  class Registry
    # @return [Hash{String => Class}] registered tool classes keyed by name
    attr_reader :tools

    def initialize
      @tools = {}
    end

    # Register a tool class. The class must respond to .tool_name.
    # @param tool_class [Class<Tools::Base>] the tool class to register
    # @return [void]
    def register(tool_class)
      @tools[tool_class.tool_name] = tool_class
    end

    # @return [Array<Hash>] schema array for the Anthropic tools API parameter
    def schemas
      @tools.values.map(&:schema)
    end

    # Instantiate and execute a tool by name.
    # @param name [String] registered tool name
    # @param input [Hash] tool input parameters
    # @return [String, Hash] tool execution result
    # @raise [UnknownToolError] if no tool is registered with the given name
    def execute(name, input)
      tool_class = @tools.fetch(name) { raise UnknownToolError, "Unknown tool: #{name}" }
      tool_class.new.execute(input)
    end

    # @param name [String] tool name to check
    # @return [Boolean] whether a tool with the given name is registered
    def registered?(name)
      @tools.key?(name)
    end

    # @return [Boolean] whether any tools are registered
    def any?
      @tools.any?
    end
  end
end
