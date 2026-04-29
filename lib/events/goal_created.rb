# frozen_string_literal: true

module Events
  # Emitted after a {Goal} record is committed for the first time.
  # The drain pipeline's {MeleteEnrichmentJob} subscribes for the
  # duration of one Melete run so a fresh goal triggers Mneme recall
  # against the updated goal set before the user's message reaches the LLM.
  class GoalCreated
    TYPE = "goal.created"

    attr_reader :session_id, :goal_id

    # @param session_id [Integer] session that owns the goal
    # @param goal_id [Integer] the newly created goal
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
