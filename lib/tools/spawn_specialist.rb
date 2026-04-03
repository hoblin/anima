# frozen_string_literal: true

module Tools
  # Spawns a named specialist sub-agent from the agent registry.
  # The specialist has a predefined system prompt and tool set defined
  # in its Markdown definition file under agents/.
  #
  # Nickname assignment is handled by the {AnalyticalBrain::Runner} which
  # runs synchronously at spawn time, generating a unique nickname based
  # on the task — same as generic sub-agents.
  #
  # Results are delivered through natural text messages routed by
  # {Events::Subscribers::SubagentMessageRouter}.
  #
  # @see Agents::Registry
  # @see Agents::Definition
  class SpawnSpecialist < Base
    include SubagentPrompts

    def self.tool_name = "spawn_specialist"

    # Builds description dynamically to include available specialists.
    def self.description
      base = "Need a specific skill set for the job? Bring in a specialist. " \
        "Its messages appear as tool responses in your conversation. " \
        "Prefix its nickname with @ to send instructions."

      registry = Agents::Registry.instance
      return base unless registry.any?

      specialist_list = registry.catalog.map { |name, desc| "- #{name}: #{desc}" }.join("\n")
      "#{base}\n\nAvailable specialists:\n#{specialist_list}"
    end

    # Builds input schema dynamically to include named agent enum.
    def self.input_schema
      {
        type: "object",
        properties: {
          name: name_property,
          task: {type: "string", description: "State the goal — the specialist knows its method."}
        },
        required: %w[name task]
      }
    end

    # @return [Hash] JSON Schema property for the name parameter
    def self.name_property
      registry = Agents::Registry.instance
      prop = {
        type: "string",
        description: "Specialist to spawn."
      }
      prop[:enum] = registry.names if registry.any?
      prop
    end

    private_class_method :name_property

    # @param session [Session] the parent session spawning the specialist
    # @param shell_session [ShellSession] the parent's persistent shell (for CWD inheritance)
    # @param agent_registry [Agents::Registry, nil] injectable for testing
    def initialize(session:, shell_session:, agent_registry: nil, **)
      @session = session
      @shell_session = shell_session
      @agent_registry = agent_registry || Agents::Registry.instance
    end

    # Creates a child session with the specialist's predefined prompt and tools,
    # persists the task as a user message, and queues background processing.
    # Returns immediately (non-blocking).
    #
    # @param input [Hash<String, Object>] with "name" and "task"
    # @return [String] confirmation with child session ID
    # @return [Hash{Symbol => String}] with :error key on validation failure
    def execute(input)
      task = input["task"].to_s.strip
      name = input["name"].to_s.strip

      return {error: "Name cannot be blank"} if name.empty?
      return {error: "Task cannot be blank"} if task.empty?

      definition = @agent_registry.get(name)
      return {error: "Unknown agent: #{name}"} unless definition

      child = spawn_child(definition, task)
      nickname = child.name
      "Specialist #{nickname} spawned (session #{child.id}). " \
        "Its messages will appear in your conversation. " \
        "To address it, prefix its name with @ in your message."
    end

    private

    def spawn_child(definition, task)
      child = Session.create!(
        parent_session_id: @session.id,
        prompt: build_prompt(definition),
        granted_tools: definition.tools,
        initial_cwd: @shell_session.pwd
      )
      create_goal_with_pinned_task(child, task)
      assign_nickname_via_brain(child)
      child.broadcast_children_update_to_parent
      AgentRequestJob.perform_later(child.id)
      child
    end

    def build_prompt(definition)
      "#{definition.prompt}\n\n#{COMMUNICATION_INSTRUCTION}"
    end
  end
end
