# frozen_string_literal: true

module Tools
  # Spawns a named specialist sub-agent from the agent registry.
  # The specialist has a predefined system prompt and tool set defined
  # in its Markdown definition file under agents/.
  #
  # Results are delivered back through {Tools::ReturnResult}.
  #
  # @see Agents::Registry
  # @see Agents::Definition
  class SpawnSpecialist < Base
    include SubagentPrompts

    def self.tool_name = "spawn_specialist"

    # Builds description dynamically to include available specialists.
    def self.description
      base = "Spawn a named specialist sub-agent to work on a task autonomously. " \
        "The specialist has a predefined role, system prompt, and tool set."

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
          task: {
            type: "string",
            description: "What the specialist should do (persisted as its first user message)"
          },
          expected_output: {
            type: "string",
            description: "Description of the expected deliverable"
          }
        },
        required: %w[name task expected_output]
      }
    end

    # @return [Hash] JSON Schema property for the name parameter
    def self.name_property
      registry = Agents::Registry.instance
      prop = {
        type: "string",
        description: "Named specialist agent to spawn from the registry."
      }
      prop[:enum] = registry.names if registry.any?
      prop
    end

    private_class_method :name_property

    # @param session [Session] the parent session spawning the specialist
    # @param agent_registry [Agents::Registry, nil] injectable for testing
    def initialize(session:, agent_registry: nil, **)
      @session = session
      @agent_registry = agent_registry || Agents::Registry.instance
    end

    # Creates a child session with the specialist's predefined prompt and tools,
    # persists the task as a user message, and queues background processing.
    # Returns immediately (non-blocking).
    #
    # @param input [Hash<String, Object>] with "name", "task", and "expected_output"
    # @return [String] confirmation with child session ID
    # @return [Hash{Symbol => String}] with :error key on validation failure
    def execute(input)
      task = input["task"].to_s.strip
      expected_output = input["expected_output"].to_s.strip
      name = input["name"].to_s.strip

      return {error: "Name cannot be blank"} if name.empty?
      return {error: "Task cannot be blank"} if task.empty?
      return {error: "Expected output cannot be blank"} if expected_output.empty?

      definition = @agent_registry.get(name)
      return {error: "Unknown agent: #{name}"} unless definition

      child = spawn_child(definition, task, expected_output)
      "Specialist '#{name}' spawned (session #{child.id}). Result will arrive as a tool response."
    end

    private

    def spawn_child(definition, task, expected_output)
      prompt = build_prompt(definition, expected_output)
      child = Session.create!(
        parent_session_id: @session.id,
        prompt: prompt,
        granted_tools: definition.tools,
        name: definition.name
      )
      child.broadcast_children_update_to_parent
      child.create_user_event(task)
      AgentRequestJob.perform_later(child.id)
      child
    end

    def build_prompt(definition, expected_output)
      "#{definition.prompt}\n\n#{RETURN_INSTRUCTION}\n\n#{EXPECTED_DELIVERABLE_PREFIX}#{expected_output}"
    end
  end
end
