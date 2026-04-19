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
    # Standard tools available to every session unless filtered out by
    # {Session#granted_tools}.
    STANDARD_TOOLS = [Tools::Bash, Tools::Read, Tools::Write, Tools::Edit, Tools::WebGet, Tools::Think, Tools::ViewMessages, Tools::SearchMessages].freeze

    # Tools that bypass {Session#granted_tools} filtering — the agent's
    # reasoning depends on them regardless of task scope.
    ALWAYS_GRANTED_TOOLS = [Tools::Think].freeze

    # Name-to-class mapping for granted-tools filtering.
    STANDARD_TOOLS_BY_NAME = STANDARD_TOOLS.index_by(&:tool_name).freeze

    class << self
      # Builds a registry appropriate for the given session: standard tools
      # filtered through {Session#granted_tools}, plus spawn tools for main
      # sessions or +mark_goal_completed+ for sub-agents, plus any tools
      # exposed by configured MCP servers.
      #
      # MCP registration warnings are emitted as system messages so both the
      # user (in verbose mode) and the LLM see them.
      #
      # @param session [Session] the session requesting tools
      # @param shell_session [ShellSession] persistent PTY for Bash-family tools
      # @return [Registry] configured registry
      def build(session:, shell_session:)
        registry = new(context: {shell_session: shell_session, session: session})

        granted_standard_tools(session).each { |tool| registry.register(tool) }

        if session.sub_agent?
          registry.register(Tools::MarkGoalCompleted)
        else
          registry.register(Tools::SpawnSubagent)
          registry.register(Tools::SpawnSpecialist)
          registry.register(Tools::OpenIssue)
        end

        Mcp::ClientManager.new.register_tools(registry).each do |message|
          Events::Bus.emit(Events::SystemMessage.new(content: message, session_id: session.id))
        end

        registry
      end

      private

      # Filters {STANDARD_TOOLS} through the session's granted list.
      # Always includes {ALWAYS_GRANTED_TOOLS} so the agent retains core
      # reasoning tools regardless of task scope.
      def granted_standard_tools(session)
        granted = session.granted_tools
        return STANDARD_TOOLS unless granted

        explicitly_granted = granted.filter_map { |name| STANDARD_TOOLS_BY_NAME[name] }
        (ALWAYS_GRANTED_TOOLS + explicitly_granted).uniq
      end
    end

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
    #   {Think} with budget-based maxLength, {Bash} with CWD in description)
    #   are instantiated with context to generate their schema:
    #   - {Think}: budget-based maxLength
    #   - {Bash}: CWD embedded in description
    # Returns tool schemas for the Anthropic API. The last schema is
    # annotated with +cache_control+ so the API caches the entire tools
    # prefix (tools are evaluated first in cache prefix order).
    def schemas
      default = Anima::Settings.tool_timeout
      result = @tools.values.map { |tool| inject_timeout(resolve_schema(tool), default) }
      result.last[:cache_control] = {type: "ephemeral"}
      result
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
    # opts out of truncation (e.g. read_file tool has its own pagination).
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

    # Returns a tool's schema, preferring the instance-level dynamic
    # variant when available. Only instantiates the tool when needed.
    def resolve_schema(tool)
      return tool.schema unless dynamic_schema?(tool)

      tool.new(**@context).dynamic_schema
    end

    def dynamic_schema?(tool)
      tool.is_a?(Class) && tool.method_defined?(:dynamic_schema)
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
