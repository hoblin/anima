# frozen_string_literal: true

module Tools
  # Spawns a generic child session that works on a task autonomously.
  # The sub-agent starts clean — no parent conversation history — with
  # only a system prompt, a Goal, and the task as its first user message.
  # Runs via {DrainJob} and communicates with the parent through
  # natural text messages routed by {Events::Subscribers::SubagentMessageRouter}.
  #
  # Nickname assignment is handled by the {Melete::Runner} which
  # runs synchronously at spawn time — the same muse that manages skills,
  # goals, and workflows for the main session.
  #
  # For named specialists with predefined prompts and tools, see {SpawnSpecialist}.
  class SpawnSubagent < Base
    include SubagentPrompts

    GENERIC_PROMPT = "#{COMMUNICATION_INSTRUCTION}\n"

    def self.tool_name = "spawn_subagent"

    def self.description
      "Task feels like a sidequest or a context-switch? Hand it off. " \
        "Starts clean with just the task — include all relevant context in the task description. " \
        "Its messages appear as tool responses in your conversation. " \
        "Prefix its nickname with @ to send instructions."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          task: {type: "string"},
          tools: {
            type: "array",
            items: {type: "string"},
            description: "Tool names to grant the sub-agent. " \
              "Omit for all standard tools. Empty array for pure reasoning. " \
              "Valid tools: #{Tools::Registry::STANDARD_TOOLS_BY_NAME.keys.join(", ")}"
          }
        },
        required: %w[task]
      }
    end

    # @param session [Session] the parent session spawning the sub-agent
    # @param shell_session [ShellSession] the parent's persistent shell (for CWD inheritance)
    def initialize(session:, shell_session:, **)
      @session = session
      @shell_session = shell_session
    end

    # Creates a child session with a clean context (no parent history),
    # runs Melete to assign a nickname, pins the task as a Goal, and
    # enqueues the task as the child's first user_message PendingMessage —
    # which kicks the standard inbound pipeline (Mneme → Melete →
    # StartProcessing → DrainJob) so the sub-agent self-starts the same
    # way a human-typed message would. Returns immediately after Melete
    # completes (blocking for ~200ms).
    #
    # @param input [Hash<String, Object>] with "task" and optional "tools"
    # @return [String] confirmation with child session ID and @nickname
    # @return [Hash{Symbol => String}] with :error key on validation failure
    def execute(input)
      task = input["task"].to_s.strip

      return {error: "Task cannot be blank"} if task.empty?

      tools = normalize_tools(input["tools"])

      error = validate_tools(tools)
      return error if error

      child = spawn_child(task, tools)
      nickname = child.name
      "Sub-agent #{nickname} spawned (session #{child.id}). " \
        "Its messages will appear in your conversation. " \
        "To address it, prefix its name with @ in your message."
    end

    private

    def spawn_child(task, granted_tools)
      child = Session.create!(
        parent_session_id: @session.id,
        prompt: GENERIC_PROMPT,
        granted_tools: granted_tools,
        initial_cwd: @shell_session.pwd
      )
      create_goal_with_pinned_task(child, task)
      assign_nickname_via_melete(child)
      child.broadcast_children_update_to_parent
      child.enqueue_user_message(task)
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

      unknown = tools - Tools::Registry::STANDARD_TOOLS_BY_NAME.keys
      return {error: "Unknown tool: #{unknown.first}"} if unknown.any?

      nil
    end
  end
end
