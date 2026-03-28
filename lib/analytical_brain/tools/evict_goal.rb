# frozen_string_literal: true

module AnalyticalBrain
  module Tools
    # Evicts a completed goal from the main agent's system prompt.
    # Evicted goals remain in the database for historical purposes but
    # no longer consume tokens in the context window.
    #
    # Only completed goals can be evicted — active goals must stay visible
    # so the agent knows what it's working on.
    class EvictGoal < ::Tools::Base
      def self.tool_name = "evict_goal"

      def self.description = "Remove a completed goal from the agent's context."

      def self.input_schema
        {
          type: "object",
          properties: {
            goal_id: {type: "integer"}
          },
          required: %w[goal_id]
        }
      end

      # @param main_session [Session] the session owning the goal
      def initialize(main_session:, **)
        @main_session = main_session
      end

      # @param input [Hash<String, Object>] with "goal_id"
      # @return [String] confirmation message
      # @return [Hash] with :error key on failure
      def execute(input)
        goal_id = input["goal_id"]
        goal = @main_session.goals.find_by(id: goal_id)
        return {error: "Goal not found (id: #{goal_id})"} unless goal

        evict(goal)
      end

      private

      def evict(goal)
        id = goal.id
        desc = goal.description
        return {error: "Cannot evict active goal: #{desc} (id: #{id})"} unless goal.completed?
        return {error: "Goal already evicted: #{desc} (id: #{id})"} if goal.evicted?

        goal.update!(evicted_at: Time.current)
        "Goal evicted: #{desc} (id: #{id})"
      end
    end
  end
end
