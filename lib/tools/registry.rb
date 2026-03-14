# frozen_string_literal: true

module Tools
  class UnknownToolError < StandardError; end

  # Manages tool registration, schema export, and dispatch.
  # Accepts both tool classes (e.g. {Tools::Base} subclasses) and tool
  # instances (e.g. {Tools::McpTool}) via duck typing. Classes are
  # instantiated with the registry's context on each execution; instances
  # are called directly since they carry their own state.
  #
  # @example
  #   registry = Tools::Registry.new(context: {shell_session: my_shell})
  #   registry.register(Tools::Bash)
  #   registry.execute("bash", {"command" => "ls"})
  class Registry
    # @return [Hash{String => Class, Object}] registered tools keyed by name
    attr_reader :tools

    # @param context [Hash] keyword arguments forwarded to every tool constructor
    def initialize(context: {})
      @tools = {}
      @context = context
    end

    # Register a tool class or instance. Must respond to +tool_name+ and +schema+.
    # @param tool [Class<Tools::Base>, #tool_name] tool class or duck-typed instance
    # @return [void]
    def register(tool)
      @tools[tool.tool_name] = tool
    end

    # @return [Array<Hash>] schema array for the Anthropic tools API parameter
    def schemas
      @tools.values.map(&:schema)
    end

    # Execute a tool by name. Classes are instantiated with the registry's
    # context; instances are called directly.
    #
    # @param name [String] registered tool name
    # @param input [Hash] tool input parameters
    # @return [String, Hash] tool execution result
    # @raise [UnknownToolError] if no tool is registered with the given name
    def execute(name, input)
      tool = @tools.fetch(name) { raise UnknownToolError, "Unknown tool: #{name}" }
      instance = tool.is_a?(Class) ? tool.new(**@context) : tool
      instance.execute(input)
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
