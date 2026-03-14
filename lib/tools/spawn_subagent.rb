# frozen_string_literal: true

module Tools
  # Spawns a child session that works on a task in parallel.
  # The sub-agent inherits the parent's viewport context at fork time,
  # runs autonomously via {AgentRequestJob}, and delivers results back
  # through {Tools::ReturnResult}.
  #
  # Supports two modes:
  # - **Named** — pass a `name` from the agent registry to spawn a specialist
  #   with predefined system prompt and tools.
  # - **Generic** — omit `name` to spawn an ad-hoc sub-agent with custom tools.
  class SpawnSubagent < Base
    RETURN_INSTRUCTION = "Complete the assigned task, then call the return_result tool with your deliverable. " \
      "Do not ask follow-up questions — work with the context you have."

    GENERIC_PROMPT = "You are a focused sub-agent. #{RETURN_INSTRUCTION}\n"

    EXPECTED_DELIVERABLE_PREFIX = "Expected deliverable: "

    def self.tool_name = "spawn_subagent"

    # Builds description dynamically to include available specialists.
    def self.description
      base = "Spawn a sub-agent to work on a task in parallel. " \
        "The sub-agent inherits your conversation context, works independently, " \
        "and returns results as a tool response when done."

      registry = Agents::Registry.instance
      return base unless registry.any?

      specialist_list = registry.catalog.map { |name, desc| "- #{name}: #{desc}" }.join("\n")
      "#{base}\n\nAvailable specialists (use the 'name' parameter):\n#{specialist_list}"
    end

    # Builds input schema dynamically to include named agent enum.
    def self.input_schema
      properties = {
        name: named_agent_property,
        task: {
          type: "string",
          description: "What the sub-agent should do (emitted as its first user message)"
        },
        expected_output: {
          type: "string",
          description: "Description of the expected deliverable"
        },
        tools: {
          type: "array",
          items: {type: "string"},
          description: "Tool names to grant a generic sub-agent (ignored when name is provided). " \
            "Omit for all standard tools. Empty array for pure reasoning (return_result only). " \
            "Valid tools: #{AgentLoop::STANDARD_TOOLS_BY_NAME.keys.join(", ")}"
        }
      }.compact

      {type: "object", properties: properties, required: %w[task expected_output]}
    end

    # @return [Hash, nil] JSON Schema property for the name parameter, or nil when no agents are loaded
    def self.named_agent_property
      registry = Agents::Registry.instance
      return nil unless registry.any?

      {
        type: "string",
        enum: registry.names,
        description: "Named specialist agent to spawn. " \
          "When provided, the agent's predefined system prompt and tools are used (tools parameter is ignored)."
      }
    end

    private_class_method :named_agent_property

    # @param session [Session] the parent session spawning the sub-agent
    # @param agent_registry [Agents::Registry, nil] injectable for testing
    def initialize(session:, agent_registry: nil, **)
      @session = session
      @agent_registry = agent_registry || Agents::Registry.instance
    end

    # Creates a child session, emits the task as a user message, and
    # queues background processing. Returns immediately (non-blocking).
    #
    # @param input [Hash<String, Object>] with "task", "expected_output", and optional "name"/"tools"
    # @return [String] confirmation with child session ID
    # @return [Hash{Symbol => String}] with :error key on validation failure
    def execute(input)
      task = input["task"].to_s.strip
      expected_output = input["expected_output"].to_s.strip
      name = input["name"]&.to_s&.strip.presence

      return {error: "Task cannot be blank"} if task.empty?
      return {error: "Expected output cannot be blank"} if expected_output.empty?

      if name
        execute_named(name, task, expected_output)
      else
        execute_generic(task, expected_output, input["tools"])
      end
    end

    private

    def execute_named(name, task, expected_output)
      definition = @agent_registry.get(name)
      return {error: "Unknown agent: #{name}"} unless definition

      child = spawn_child(prompt: build_named_prompt(definition, expected_output), granted_tools: definition.tools, task: task)
      "Sub-agent '#{name}' spawned (session #{child.id}). Result will arrive as a tool response."
    end

    def execute_generic(task, expected_output, raw_tools)
      tools = normalize_tools(raw_tools)

      error = validate_tools(tools)
      return error if error

      child = spawn_child(prompt: build_generic_prompt(expected_output), granted_tools: tools, task: task)
      "Sub-agent spawned (session #{child.id}). Result will arrive as a tool response."
    end

    def spawn_child(prompt:, granted_tools:, task:)
      child = create_child_session(prompt: prompt, granted_tools: granted_tools)
      emit_task(child, task)
      AgentRequestJob.perform_later(child.id)
      child
    end

    # Normalizes tool names to lowercase and removes duplicates.
    # Returns non-array values unchanged for {#validate_tools} to catch.
    #
    # @param tools [Array, nil, Object] raw tools parameter from LLM
    # @return [Array<String>, nil, Object] normalized tools
    def normalize_tools(tools)
      return nil unless tools
      return tools unless tools.is_a?(Array)

      tools.map { |tool| tool.to_s.downcase }.uniq
    end

    # @param tools [Array<String>, nil, Object] normalized tools parameter
    # @return [Hash{Symbol => String}, nil] error hash if invalid, nil if valid
    def validate_tools(tools)
      return nil unless tools
      return {error: "tools must be an array"} unless tools.is_a?(Array)

      unknown = tools - AgentLoop::STANDARD_TOOLS_BY_NAME.keys
      return {error: "Unknown tool: #{unknown.first}"} if unknown.any?

      nil
    end

    def create_child_session(prompt:, granted_tools: nil)
      Session.create!(
        parent_session_id: @session.id,
        prompt: prompt,
        granted_tools: granted_tools
      )
    end

    def build_generic_prompt(expected_output)
      "#{GENERIC_PROMPT}\n#{EXPECTED_DELIVERABLE_PREFIX}#{expected_output}"
    end

    def build_named_prompt(definition, expected_output)
      "#{definition.prompt}\n\n#{RETURN_INSTRUCTION}\n\n#{EXPECTED_DELIVERABLE_PREFIX}#{expected_output}"
    end

    def emit_task(child, task)
      Events::Bus.emit(Events::UserMessage.new(content: task, session_id: child.id))
    end
  end
end
