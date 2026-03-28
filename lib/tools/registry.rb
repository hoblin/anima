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

    # @return [Array<Hash>] schema array for the Anthropic tools API parameter.
    #   Each schema includes an optional `timeout` parameter (seconds) injected
    #   by the registry. The agent can override the default per call for
    #   long-running operations. Tools with session-dependent schemas (e.g.
    #   {Think} with budget-based maxLength) are instantiated with context
    #   to generate their schema.
    def schemas
      default = Anima::Settings.tool_timeout
      @tools.values.map { |tool| inject_timeout(resolve_schema(tool), default) }
    end

    # Execute a tool by name. Classes are instantiated with the registry's
    # context; instances are called directly.
    #
    # @param name [String] registered tool name
    # @param input [Hash] tool input parameters (may include "timeout" for
    #   tools that support per-call timeout overrides)
    # @return [String, Hash] tool execution result
    # @raise [UnknownToolError] if no tool is registered with the given name
    def execute(name, input)
      tool = @tools.fetch(name) { raise UnknownToolError, "Unknown tool: #{name}" }
      instance = tool.is_a?(Class) ? tool.new(**@context) : tool
      instance.execute(input)
    end

    # Returns the truncation threshold for a tool, or +nil+ if the tool
    # opts out of truncation (e.g. ReadTool has its own pagination).
    # MCP tools and other duck-typed instances use the default threshold.
    #
    # @param name [String] registered tool name
    # @return [Integer, nil] character threshold, or nil to skip truncation
    def truncation_threshold(name)
      tool = @tools[name]
      return tool.truncation_threshold if tool&.respond_to?(:truncation_threshold)

      Anima::Settings.max_tool_response_chars
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

    private

    # Returns a tool's schema, preferring the instance-level budget-aware
    # variant when available. Only instantiates the tool when needed.
    def resolve_schema(tool)
      return tool.schema unless budget_aware?(tool)

      tool.new(**@context).schema_with_budget
    end

    def budget_aware?(tool)
      tool.is_a?(Class) && tool.method_defined?(:schema_with_budget)
    end

    # Injects an optional `timeout` parameter into the tool's input schema.
    def inject_timeout(schema, default)
      result = schema.deep_dup
      input = result[:input_schema] ||= {type: "object", properties: {}}
      props = input[:properties] ||= {}
      props["timeout"] = {
        type: "integer",
        description: "Seconds (default: #{default})."
      }
      result
    end
  end
end
