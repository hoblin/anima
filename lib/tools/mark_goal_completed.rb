# frozen_string_literal: true

module Tools
  # Signals sub-agent task completion by marking its assigned Goal as
  # completed and routing the result back to the parent session.
  #
  # Only available to sub-agent sessions (those with a +parent_session+).
  # This is the explicit "finish line" that prevents runaway sub-agents
  # from continuing past their assigned task.
  #
  # The result text is delivered to the parent session as a user message
  # attributed to the sub-agent, identical to how regular sub-agent
  # messages are routed by {Events::Subscribers::SubagentMessageRouter}.
  #
  # @example Sub-agent completing its task
  #   mark_goal_completed(result: "Found 3 N+1 queries in the orders controller.")
  class MarkGoalCompleted < Base
    def self.tool_name = "mark_goal_completed"

    def self.description = "Deliver result to parent. Stop working after this call."

    def self.input_schema
      {
        type: "object",
        properties: {
          result: {type: "string"}
        },
        required: %w[result]
      }
    end

    # @param session [Session] the sub-agent session
    def initialize(session:, **)
      @session = session
    end

    # Completes the sub-agent's assigned goal and routes the result
    # to the parent session.
    #
    # @param input [Hash<String, Object>] with "result"
    # @return [String] confirmation message
    # @return [Hash{Symbol => String}] with :error key on failure
    def execute(input)
      result = input["result"].to_s.strip
      return {error: "Result cannot be blank"} if result.empty?

      goal = @session.goals.active.root.first
      return {error: "No active goal found"} unless goal

      complete_goal(goal)
      route_result_to_parent(result)

      "Done. Result delivered to parent."
    end

    private

    def complete_goal(goal)
      Goal.transaction do
        goal.update!(status: "completed", completed_at: Time.current)
        goal.cascade_completion!
        goal.release_orphaned_pins!
      end
    end

    # Delivers the sub-agent's result to the parent session as an
    # attributed user message. Truncates oversized results to protect
    # the parent's context window. No-op when the parent session is absent.
    #
    # @param result [String] the sub-agent's findings to forward
    # @return [void]
    def route_result_to_parent(result)
      parent = @session.parent_session
      return unless parent

      name = @session.name || "agent-#{@session.id}"
      truncated = Tools::ResponseTruncator.truncate(
        result, threshold: Anima::Settings.max_subagent_response_chars
      )
      attributed = "[sub-agent @#{name}]: #{truncated}"
      parent.enqueue_user_message(attributed)
    end
  end
end
