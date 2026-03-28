# frozen_string_literal: true

module Tools
  # Shared prompt fragments and spawn logic for tools that create sub-agent sessions.
  # Included by {SpawnSubagent} and {SpawnSpecialist} to avoid duplication.
  module SubagentPrompts
    COMMUNICATION_INSTRUCTION = "Your text messages are automatically forwarded to the parent agent. " \
      "When you finish your task, call mark_goal_completed with your findings. " \
      "If you need clarification, just ask — the parent can reply."

    # Framing message inserted as the sub-agent's first user message.
    # Explains forked context and redirects attention to the assigned Goal.
    FORK_FRAMING_MESSAGE = "The conversation above is forked from the main agent's context. " \
      "The goals described there belong to the main agent, not you. " \
      "You were spawned to help with a single task — it's described in your Goal. " \
      "Complete it and call mark_goal_completed."

    private

    # Creates the sub-agent's Goal from the task description and inserts
    # the framing message as the first user message.
    #
    # @param child [Session] the newly created child session
    # @param task [String] the task description to pin as the sole Goal
    # @return [void]
    def pin_goal_and_frame(child, task)
      child.goals.create!(description: task)
      child.create_user_message(FORK_FRAMING_MESSAGE)
    end

    # Runs the analytical brain synchronously to assign a nickname.
    # Falls back to a sequential "agent-N" name on any failure.
    def assign_nickname_via_brain(child)
      AnalyticalBrain::Runner.new(child).call
      child.reload
    rescue => error
      Rails.logger.warn("Sub-agent nickname assignment failed: #{error.message}")
      child.update!(name: fallback_nickname)
    end

    def fallback_nickname
      "agent-#{@session.child_sessions.count}"
    end
  end
end
