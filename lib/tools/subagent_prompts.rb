# frozen_string_literal: true

module Tools
  # Shared prompt fragments and spawn logic for tools that create sub-agent sessions.
  # Included by {SpawnSubagent} and {SpawnSpecialist} to avoid duplication.
  module SubagentPrompts
    # Prepended to every sub-agent's stored prompt after nickname assignment.
    # Establishes identity before any other instruction — the sub-agent knows
    # who it is and how to recognize messages directed at it.
    IDENTITY_TEMPLATE = "You are @%s, a sub-agent of the primary agent.\n" \
      "Messages mentioning @%s are addressed to you."

    COMMUNICATION_INSTRUCTION = "Your messages reach the parent automatically. " \
      "Ask if you need clarification — the parent can reply."

    # Framing message inserted as the sub-agent's first user message.
    # This is the "brake" between inherited parent context and the sub-agent's
    # own task — without it, the model continues the parent's trajectory.
    FORK_FRAMING_MESSAGE = "You were spawned to help with a single task. " \
      "The messages above are the parent agent's context — background for your work, " \
      "but the parent's goals are not yours. " \
      "Your sole task is described in your Goal."

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

    # Runs the analytical brain synchronously to assign a nickname,
    # then prepends identity context to the stored prompt.
    # Falls back to a sequential "agent-N" name on any failure.
    # Identity injection runs in +ensure+ so it applies to both
    # brain-assigned and fallback nicknames.
    def assign_nickname_via_brain(child)
      AnalyticalBrain::Runner.new(child).call
      child.reload
    rescue => error
      Rails.logger.warn("Sub-agent nickname assignment failed: #{error.message}")
      child.update!(name: fallback_nickname)
    ensure
      inject_identity_context(child)
    end

    # Prepends identity context (nickname + sub-agent status) to the child's
    # stored prompt. Called after nickname assignment so the sub-agent knows
    # who it is from first token.
    #
    # @param child [Session] the child session with a nickname already set
    # @return [void]
    def inject_identity_context(child)
      nickname = child.name
      identity = format(IDENTITY_TEMPLATE, nickname, nickname)
      child.update!(prompt: "#{identity}\n#{child.prompt}")
    end

    def fallback_nickname
      "agent-#{@session.child_sessions.count}"
    end
  end
end
