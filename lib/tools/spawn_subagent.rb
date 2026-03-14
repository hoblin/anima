# frozen_string_literal: true

module Tools
  # Spawns a child session that works on a task in parallel.
  # The sub-agent inherits the parent's viewport context at fork time,
  # runs autonomously via {AgentRequestJob}, and delivers results back
  # through {Tools::ReturnResult}.
  class SpawnSubagent < Base
    SUBAGENT_PROMPT = <<~PROMPT
      You are a focused sub-agent. Complete the assigned task, then call the return_result tool with your deliverable.
      Do not ask follow-up questions — work with the context you have.
    PROMPT

    EXPECTED_DELIVERABLE_PREFIX = "Expected deliverable: "

    def self.tool_name = "spawn_subagent"

    def self.description = "Spawn a sub-agent to work on a task in parallel. " \
      "The sub-agent inherits your conversation context, works independently, " \
      "and returns results as a tool response when done."

    def self.input_schema
      {
        type: "object",
        properties: {
          task: {
            type: "string",
            description: "What the sub-agent should do (emitted as its first user message)"
          },
          expected_output: {
            type: "string",
            description: "Description of the expected deliverable"
          }
        },
        required: %w[task expected_output]
      }
    end

    # @param session [Session] the parent session spawning the sub-agent
    def initialize(session:, **)
      @session = session
    end

    # Creates a child session, emits the task as a user message, and
    # queues background processing. Returns immediately (non-blocking).
    #
    # @param input [Hash<String, Object>] with "task" and "expected_output" keys
    # @return [String] confirmation with child session ID
    # @return [Hash] with :error key on validation failure
    def execute(input)
      task = input["task"].to_s.strip
      expected_output = input["expected_output"].to_s.strip
      return {error: "Task cannot be blank"} if task.empty?
      return {error: "Expected output cannot be blank"} if expected_output.empty?

      child = create_child_session(expected_output)
      emit_task(child, task)
      AgentRequestJob.perform_later(child.id)

      "Sub-agent spawned (session #{child.id}). Result will arrive as a tool response."
    end

    private

    def create_child_session(expected_output)
      Session.create!(
        parent_session_id: @session.id,
        prompt: build_prompt(expected_output)
      )
    end

    def build_prompt(expected_output)
      "#{SUBAGENT_PROMPT}\n#{EXPECTED_DELIVERABLE_PREFIX}#{expected_output}"
    end

    def emit_task(child, task)
      Events::Bus.emit(Events::UserMessage.new(content: task, session_id: child.id))
    end
  end
end
