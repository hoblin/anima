# frozen_string_literal: true

module Events
  # Emitted after a {Goal}'s description is changed and the change is
  # committed. Status-only updates (finish_goal, cascade completion,
  # mark_goal_completed) do not emit — a completed goal carries no new
  # search seed for Mneme.
  #
  # The drain pipeline's {MeleteEnrichmentJob} subscribes for the
  # duration of one Melete run so a refined goal triggers Mneme recall
  # against the updated wording before the user's message reaches the LLM.
  class GoalUpdated
    TYPE = "goal.updated"

    attr_reader :session_id, :goal_id

    # @param session_id [Integer] session that owns the goal
    # @param goal_id [Integer] the updated goal
    def initialize(session_id:, goal_id:)
      @session_id = session_id
      @goal_id = goal_id
    end

    def event_name
      "#{Bus::NAMESPACE}.#{TYPE}"
    end

    def to_h
      {type: TYPE, session_id:, goal_id:}
    end
  end
end
