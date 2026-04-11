# frozen_string_literal: true

module Melete
  module Tools
    # Reads and activates a workflow on the main session.
    # Returns the full workflow content so the brain can create goals from it.
    # The workflow's content enters the conversation as a phantom
    # tool_use/tool_result pair through the {PendingMessage} promotion flow.
    class ReadWorkflow < ::Tools::Base
      def self.tool_name = "read_workflow"

      def self.description = "Activate a workflow and return its content for goal planning."

      def self.input_schema
        {
          type: "object",
          properties: {
            workflow_name: {type: "string"}
          },
          required: %w[workflow_name]
        }
      end

      # @param main_session [Session] the session to activate the workflow on
      def initialize(main_session:, **)
        @main_session = main_session
      end

      # @param input [Hash<String, Object>] with "workflow_name" key
      # @return [String] workflow name, description, and full content
      # @return [Hash] with :error key on validation failure
      def execute(input)
        workflow_name = input["workflow_name"].to_s.strip
        return {error: "Workflow name cannot be blank"} if workflow_name.empty?

        workflow = @main_session.activate_workflow(workflow_name)
        format_workflow(workflow)
      rescue Workflows::InvalidDefinitionError => error
        {error: error.message}
      end

      private

      def format_workflow(workflow)
        <<~CONTENT
          Workflow: #{workflow.name}
          Description: #{workflow.description}

          #{workflow.content}
        CONTENT
      end
    end
  end
end
