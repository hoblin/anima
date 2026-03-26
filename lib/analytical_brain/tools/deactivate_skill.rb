# frozen_string_literal: true

module AnalyticalBrain
  module Tools
    # Deactivates a domain knowledge skill on the main session.
    # The skill's content is removed from the main agent's system prompt.
    class DeactivateSkill < ::Tools::Base
      def self.tool_name = "deactivate_skill"

      def self.description = "Remove a skill's content from the agent's context."

      def self.input_schema
        {
          type: "object",
          properties: {
            name: {type: "string"}
          },
          required: %w[name]
        }
      end

      # @param main_session [Session] the session to deactivate the skill on
      def initialize(main_session:, **)
        @main_session = main_session
      end

      # @param input [Hash<String, Object>] with "name" key
      # @return [String] confirmation message
      # @return [Hash] with :error key on validation failure
      def execute(input)
        skill_name = input["name"].to_s.strip
        return {error: "Skill name cannot be blank"} if skill_name.empty?

        @main_session.deactivate_skill(skill_name)
        "Deactivated skill: #{skill_name}"
      end
    end
  end
end
