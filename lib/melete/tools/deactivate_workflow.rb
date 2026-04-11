# frozen_string_literal: true

module Melete
  module Tools
    # Deactivates the current workflow on the main session.
    # The workflow's recalled message stays in the conversation and
    # evicts naturally from the sliding window.
    class DeactivateWorkflow < ::Tools::Base
      def self.tool_name = "deactivate_workflow"

      def self.description = "Deactivate the current workflow when it is complete or no longer relevant."

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
