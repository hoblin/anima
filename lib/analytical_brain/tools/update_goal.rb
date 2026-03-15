# frozen_string_literal: true

module AnalyticalBrain
  module Tools
    # Updates a goal's description on the main session. Useful when the
    # brain refines its understanding mid-conversation — e.g. "implement auth"
    # becomes "implement OAuth2 middleware for API endpoints".
    class UpdateGoal < ::Tools::Base
      def self.tool_name = "update_goal"

      def self.description = "Update a goal's description. " \
        "Use this to refine a goal as understanding evolves."

      def self.input_schema
        {
          type: "object",
          properties: {
            goal_id: {
              type: "integer",
              description: "ID of the goal to update"
            },
            description: {
              type: "string",
              description: "New description for the goal (1-2 sentences)"
            }
          },
          required: %w[goal_id description]
        }
      end

      # @param main_session [Session] the session owning the goal
      def initialize(main_session:, **)
        @main_session = main_session
      end

      # @param input [Hash<String, Object>] with "goal_id" and "description"
      # @return [String] confirmation message
      # @return [Hash] with :error key on failure
      def execute(input)
        goal_id = input["goal_id"]
        description = input["description"].to_s.strip
        return {error: "Description cannot be blank"} if description.empty?

        goal = @main_session.goals.find_by(id: goal_id)
        return {error: "Goal not found (id: #{goal_id})"} unless goal
        return {error: "Cannot update completed goal: #{goal.description} (id: #{goal_id})"} if goal.completed?

        goal.update!(description: description)
        "Goal updated: #{description} (id: #{goal_id})"
      end
    end
  end
end
