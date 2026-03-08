# frozen_string_literal: true

module Tools
  class UnknownToolError < StandardError; end

  # Manages tool registration, schema export, and dispatch.
  # Tools are registered by class and looked up by name at execution time.
  # An optional context hash is passed to each tool's constructor, allowing
  # shared dependencies (e.g. a {ShellSession}) to reach tools that need them.
  #
  # @example
  #   registry = Tools::Registry.new(context: {shell_session: my_shell})
  #   registry.register(Tools::Bash)
  #   registry.execute("bash", {"command" => "ls"})
  class Registry
    # @return [Hash{String => Class}] registered tool classes keyed by name
    attr_reader :tools

    # @param context [Hash] keyword arguments forwarded to every tool constructor
    def initialize(context: {})
      @tools = {}
      @context = context
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

    # Instantiate and execute a tool by name. The registry's context is
    # forwarded to the tool constructor as keyword arguments.
    #
    # @param name [String] registered tool name
    # @param input [Hash] tool input parameters
    # @return [String, Hash] tool execution result
    # @raise [UnknownToolError] if no tool is registered with the given name
    def execute(name, input)
      tool_class = @tools.fetch(name) { raise UnknownToolError, "Unknown tool: #{name}" }
      tool_class.new(**@context).execute(input)
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
