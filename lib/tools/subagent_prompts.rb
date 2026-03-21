# frozen_string_literal: true

module Tools
  # Shared prompt fragments for tools that spawn sub-agent sessions.
  # Included by {SpawnSubagent} and {SpawnSpecialist} to avoid duplication.
  module SubagentPrompts
    COMMUNICATION_INSTRUCTION = "Your text messages are automatically forwarded to the parent agent. " \
      "When you finish, write your final summary and stop — no special tool needed. " \
      "If you need clarification, just ask — the parent can reply."

    EXPECTED_DELIVERABLE_PREFIX = "Expected deliverable: "
  end
end
