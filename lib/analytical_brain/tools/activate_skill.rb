# frozen_string_literal: true

module AnalyticalBrain
  module Tools
    # Activates a domain knowledge skill on the main session.
    # The skill's content enters the conversation as a phantom
    # tool_use/tool_result pair through the {PendingMessage} promotion flow.
    class ActivateSkill < ::Tools::Base
      def self.tool_name = "activate_skill"

      def self.description = "Give the agent domain knowledge relevant to the current conversation."

      def self.input_schema
        {
          type: "object",
          properties: {
            skill_name: {type: "string"}
          },
          required: %w[skill_name]
        }
      end

      # @param main_session [Session] the session to activate the skill on
      def initialize(main_session:, **)
        @main_session = main_session
      end

      # @param input [Hash<String, Object>] with "skill_name" key
      # @return [String] confirmation message with skill description
      # @return [Hash] with :error key on validation failure
      def execute(input)
        skill_name = input["skill_name"].to_s.strip
        return {error: "Skill name cannot be blank"} if skill_name.empty?

        skill = @main_session.activate_skill(skill_name)
        format_confirmation(skill)
      rescue Skills::InvalidDefinitionError => error
        {error: error.message}
      end

      private

      def format_confirmation(skill)
        "Activated skill: #{skill.name} (#{skill.description})"
      end
    end
  end
end
