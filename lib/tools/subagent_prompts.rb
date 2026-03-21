# frozen_string_literal: true

module Tools
  # Shared prompt fragments and nickname logic for tools that spawn sub-agent sessions.
  # Included by {SpawnSubagent} and {SpawnSpecialist} to avoid duplication.
  module SubagentPrompts
    COMMUNICATION_INSTRUCTION = "Your text messages are automatically forwarded to the parent agent. " \
      "When you finish, write your final summary and stop — no special tool needed. " \
      "If you need clarification, just ask — the parent can reply."

    EXPECTED_DELIVERABLE_PREFIX = "Expected deliverable: "

    private

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
