# frozen_string_literal: true

module AnalyticalBrain
  module Tools
    # Deactivates the current workflow on the main session.
    # The workflow's content is removed from the main agent's system prompt.
    class DeactivateWorkflow < ::Tools::Base
      def self.tool_name = "deactivate_workflow"

      def self.description = "Deactivate the current workflow."

      def self.input_schema
        {
          type: "object",
          properties: {},
          required: []
        }
      end

      # @param main_session [Session] the session to deactivate the workflow on
      def initialize(main_session:, **)
        @main_session = main_session
      end

      # @param input [Hash<String, Object>] (no parameters needed)
      # @return [String] confirmation message
      def execute(_input)
        previous = @main_session.active_workflow
        @main_session.deactivate_workflow
        previous ? "Deactivated workflow: #{previous}" : "No workflow was active"
      end
    end
  end
end
