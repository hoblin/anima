# frozen_string_literal: true

module AnalyticalBrain
  module Tools
    # Activates a domain knowledge skill on the main session.
    # The skill's content is injected into the main agent's system prompt,
    # making the knowledge available for the current and future responses.
    class ActivateSkill < ::Tools::Base
      def self.tool_name = "activate_skill"

      def self.description = "Inject a skill's content into the agent's context."

      def self.input_schema
        {
          type: "object",
          properties: {
            name: {type: "string"}
          },
          required: %w[name]
        }
      end

      # @param main_session [Session] the session to activate the skill on
      def initialize(main_session:, **)
        @main_session = main_session
      end

      # @param input [Hash<String, Object>] with "name" key
      # @return [String] confirmation message with skill description
      # @return [Hash] with :error key on validation failure
      def execute(input)
        skill_name = input["name"].to_s.strip
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
