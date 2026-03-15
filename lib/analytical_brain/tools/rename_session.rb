# frozen_string_literal: true

module AnalyticalBrain
  module Tools
    # Renames the main session with an emoji and short descriptive name.
    # Operates on the main session passed through the registry context,
    # not on the phantom analytical brain session.
    #
    # The analytical brain calls this when a conversation's topic becomes
    # clear or shifts significantly enough to warrant a new name.
    class RenameSession < ::Tools::Base
      def self.tool_name = "rename_session"

      def self.description = "Rename the conversation session. " \
        "Use one emoji followed by 1-3 descriptive words."

      def self.input_schema
        {
          type: "object",
          properties: {
            emoji: {
              type: "string",
              description: "A single emoji representing the conversation topic"
            },
            name: {
              type: "string",
              description: "1-3 word descriptive name for the session"
            }
          },
          required: %w[emoji name]
        }
      end

      # @param main_session [Session] the session to rename
      def initialize(main_session:, **)
        @main_session = main_session
      end

      # @param input [Hash<String, Object>] with "emoji" and "name" keys
      # @return [String] confirmation message
      # @return [Hash] with :error key on validation failure
      def execute(input)
        error = validate(input)
        return error if error

        full_name = build_name(input)
        @main_session.update!(name: full_name)
        "Session renamed to: #{full_name}"
      end

      private

      def validate(input)
        return {error: "Emoji cannot be blank"} if input["emoji"].to_s.strip.empty?
        {error: "Name cannot be blank"} if input["name"].to_s.strip.empty?
      end

      def build_name(input)
        "#{input["emoji"].to_s.strip} #{input["name"].to_s.strip}".truncate(255)
      end
    end
  end
end
