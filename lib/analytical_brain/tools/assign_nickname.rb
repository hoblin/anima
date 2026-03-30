# frozen_string_literal: true

module AnalyticalBrain
  module Tools
    # Assigns a static nickname to a sub-agent session.
    # Operates on the session passed through the registry context.
    #
    # Nicknames must be unique among active siblings — the tool returns
    # an error on collision so the LLM can pick another name naturally,
    # without programmatic suffixes.
    #
    # @see AnalyticalBrain::Runner — invokes this tool for child sessions
    class AssignNickname < ::Tools::Base
      # Lowercase hyphenated words: "loop-sleuth", "api-scout", "test-fixer"
      NICKNAME_PATTERN = /\A[a-z][a-z0-9]*(-[a-z0-9]+)*\z/
      MAX_LENGTH = 30

      def self.tool_name = "assign_nickname"

      def self.description = "Assign a permanent nickname to this sub-agent."

      def self.input_schema
        {
          type: "object",
          properties: {
            nickname: {
              type: "string",
              description: "Lowercase, hyphenated (e.g. 'loop-sleuth')."
            }
          },
          required: %w[nickname]
        }
      end

      # @param main_session [Session] the sub-agent session to name
      def initialize(main_session:, **)
        @session = main_session
      end

      # @param input [Hash<String, Object>] with "nickname" key
      # @return [String] confirmation message
      # @return [Hash] with :error key on validation failure
      def execute(input)
        nickname = input["nickname"].to_s.strip.downcase

        error = validate(nickname)
        return error if error

        @session.update!(name: nickname)
        "Nickname set to #{nickname}"
      end

      private

      def validate(nickname)
        return {error: "Nickname cannot be blank"} if nickname.empty?
        return {error: "Invalid format: use 1-3 lowercase words joined by hyphens"} unless nickname.match?(NICKNAME_PATTERN)
        return {error: "Nickname too long (max #{MAX_LENGTH} chars)"} if nickname.length > MAX_LENGTH

        if sibling_nickname_taken?(nickname)
          {error: "Nickname '#{nickname}' is already taken by a sibling. Choose another."}
        end
      end

      def sibling_nickname_taken?(nickname)
        return false unless @session.parent_session

        @session.parent_session.child_sessions
          .where.not(id: @session.id)
          .exists?(name: nickname)
      end
    end
  end
end
