# frozen_string_literal: true

module Tools
  # Sub-agent-only tool that delivers a completed result back to the
  # parent session as a tool_call/tool_response pair. The parent agent
  # sees it as if it called a tool itself — no custom event types needed.
  #
  # Never registered for main sessions — only sub-agents see this tool.
  class ReturnResult < Base
    def self.tool_name = "return_result"

    def self.description = "Return your completed result to the parent agent. " \
      "Call this when you have fulfilled the assigned task."

    def self.input_schema
      {
        type: "object",
        properties: {
          result: {
            type: "string",
            description: "The completed deliverable to send back to the parent agent"
          }
        },
        required: ["result"]
      }
    end

    # @param session [Session] the sub-agent session returning a result
    def initialize(session:, **)
      @session = session
    end

    # Emits a tool_call/tool_response pair in the parent session so the
    # parent agent sees the sub-agent result as a regular tool interaction.
    #
    # @param input [Hash<String, Object>] with "result" key
    # @return [String, Hash] confirmation message, or Hash with :error key on failure
    def execute(input)
      result = input["result"].to_s.strip
      return {error: "Result cannot be blank"} if result.empty?

      parent = @session.parent_session
      return {error: "No parent session — only sub-agents can return results"} unless parent

      tool_use_id = "toolu_subagent_#{@session.id}"
      task = extract_task
      # Specialists are spawned with a name from the registry; generic sub-agents have nil name.
      origin_tool = @session.name ? SpawnSpecialist.tool_name : SpawnSubagent.tool_name

      Events::Bus.emit(Events::ToolCall.new(
        content: "Sub-agent result (session #{@session.id})",
        tool_name: origin_tool,
        tool_input: {"task" => task, "session_id" => @session.id},
        tool_use_id: tool_use_id,
        session_id: parent.id
      ))

      Events::Bus.emit(Events::ToolResponse.new(
        content: result,
        tool_name: origin_tool,
        tool_use_id: tool_use_id,
        session_id: parent.id
      ))

      "Result delivered to parent session #{parent.id}."
    end

    private

    # Extracts the original task from the sub-agent's first user message.
    # @return [String]
    def extract_task
      @session.events
        .where(event_type: "user_message")
        .order(:id)
        .pick(:payload)
        &.dig("content")
        .to_s
    end
  end
end
