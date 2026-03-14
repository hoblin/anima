# frozen_string_literal: true

module Tools
  # Shared prompt fragments for tools that spawn sub-agent sessions.
  # Included by {SpawnSubagent} and {SpawnSpecialist} to avoid duplication.
  module SubagentPrompts
    RETURN_INSTRUCTION = "Complete the assigned task, then call the return_result tool with your deliverable. " \
      "Do not ask follow-up questions — work with the context you have."

    EXPECTED_DELIVERABLE_PREFIX = "Expected deliverable: "
  end
end
