# frozen_string_literal: true

module AnalyticalBrain
  module Tools
    # Reads and activates a workflow on the main session.
    # Returns the full workflow content so the brain can create goals from it.
    # Also sets the workflow as active on the session, injecting its content
    # into the main agent's "Your Expertise" section.
    class ReadWorkflow < ::Tools::Base
      def self.tool_name = "read_workflow"

      def self.description = "Read a workflow's full content and activate it on the session. " \
        "Use the content to create appropriate goals with set_goal."

      def self.input_schema
        {
          type: "object",
          properties: {
            name: {
              type: "string",
              description: "Name of the workflow to read (from the available workflows list)"
            }
          },
          required: %w[name]
        }
      end

      # @param main_session [Session] the session to activate the workflow on
      def initialize(main_session:, **)
        @main_session = main_session
      end

      # @param input [Hash<String, Object>] with "name" key
      # @return [String] workflow name, description, and full content
      # @return [Hash] with :error key on validation failure
      def execute(input)
        workflow_name = input["name"].to_s.strip
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
