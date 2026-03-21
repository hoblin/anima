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

      # Marks the goal as completed. Root goals cascade completion to all
      # active sub-goals within a single transaction so the after_commit
      # broadcast includes the fully cascaded state.
      #
      # Returns an error for already-completed goals so the analytical
      # brain learns to check status before retrying.
      def complete(goal)
        id = goal.id
        return {error: "Goal already completed: #{goal.description} (id: #{id})"} if goal.completed?

        released = 0
        Goal.transaction do
          goal.update!(status: "completed", completed_at: Time.current)
          goal.cascade_completion! if goal.root?
          released = goal.release_orphaned_pins!
        end

        msg = "Goal completed: #{goal.description} (id: #{id})"
        msg += " (released #{released} orphaned pins)" if released > 0
        msg
      end
    end
  end
end
