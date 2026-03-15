# frozen_string_literal: true

module AnalyticalBrain
  module Tools
    # Marks a goal as completed on the main session. Sets the status to
    # "completed" and records the completion timestamp.
    class FinishGoal < ::Tools::Base
      def self.tool_name = "finish_goal"

      def self.description = "Mark a goal as completed. " \
        "Use this when the main agent has finished the work described by the goal."

      def self.input_schema
        {
          type: "object",
          properties: {
            goal_id: {
              type: "integer",
              description: "ID of the goal to mark as completed"
            }
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

        complete(goal)
      end

      private

      # Idempotent guard: the analytical brain may retry completion on
      # a goal it already finished. Returning an error lets it learn to
      # check status first rather than silently succeeding.
      #
      # When a root goal completes, all active sub-goals are marked completed
      # too — parent completion means the semantic episode is done.
      def complete(goal)
        id = goal.id
        return {error: "Goal already completed: #{goal.description} (id: #{id})"} if goal.completed?

        goal.update!(status: "completed", completed_at: Time.current)
        goal.cascade_completion! if goal.root?
        "Goal completed: #{goal.description} (id: #{id})"
      end
    end
  end
end
