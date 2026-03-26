# frozen_string_literal: true

module AnalyticalBrain
  module Tools
    # Creates a goal on the main session. Root goals represent high-level
    # objectives (semantic episodes); sub-goals are TODO-style steps within
    # a root goal. The two-level hierarchy is enforced by the Goal model.
    class SetGoal < ::Tools::Base
      def self.tool_name = "set_goal"

      def self.description = "Create a goal or sub-goal."

      def self.input_schema
        {
          type: "object",
          properties: {
            description: {
              type: "string",
              description: "1-2 sentences."
            },
            parent_goal_id: {type: "integer"}
          },
          required: %w[description]
        }
      end

      # @param main_session [Session] the session to create the goal on
      def initialize(main_session:, **)
        @main_session = main_session
      end

      # @param input [Hash<String, Object>] with "description" and optional "parent_goal_id"
      # @return [String] confirmation with goal ID
      # @return [Hash] with :error key on validation failure
      def execute(input)
        description = input["description"].to_s.strip
        return {error: "Description cannot be blank"} if description.empty?

        goal = @main_session.goals.create!(
          description: description,
          parent_goal_id: input["parent_goal_id"]
        )
        format_confirmation(goal)
      rescue ActiveRecord::RecordInvalid => error
        {error: error.record.errors.full_messages.join(", ")}
      end

      private

      def format_confirmation(goal)
        prefix = goal.parent_goal_id ? "Sub-goal" : "Goal"
        "#{prefix} created: #{goal.description} (id: #{goal.id})"
      end
    end
  end
end
