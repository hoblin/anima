# frozen_string_literal: true

module Mneme
  module Tools
    # Saves a summary snapshot of conversation context that is about to
    # leave the viewport. The snapshot captures the "gist" of what happened
    # so the agent retains awareness of past context.
    #
    # The text field has a max_tokens limit for predictable sizing — each
    # snapshot is a fixed-size tile, enabling calculation of how many fit
    # at each compression level.
    class SaveSnapshot < ::Tools::Base
      def self.tool_name = "save_snapshot"

      def self.description = "Summarize what's leaving the viewport."

      def self.input_schema
        {
          type: "object",
          properties: {
            text: {
              type: "string",
              maxLength: Anima::Settings.mneme_max_tokens * TokenEstimation::BYTES_PER_TOKEN
            }
          },
          required: %w[text]
        }
      end

      # @param main_session [Session] the session being observed
      # @param from_message_id [Integer] first message ID covered by this snapshot
      # @param to_message_id [Integer] last message ID covered by this snapshot
      # @param level [Integer] compression level (1 = from messages, 2 = from L1 snapshots)
      def initialize(main_session:, from_message_id:, to_message_id:, level: 1, **)
        @main_session = main_session
        @from_message_id = from_message_id
        @to_message_id = to_message_id
        @level = level
      end

      def execute(input)
        text = input["text"].to_s.strip
        return "Error: Summary text cannot be blank" if text.empty?

        snapshot = @main_session.snapshots.create!(
          text: text,
          from_message_id: @from_message_id,
          to_message_id: @to_message_id,
          level: @level
        )

        "Snapshot saved (id: #{snapshot.id}, messages #{@from_message_id}..#{@to_message_id})"
      end
    end
  end
end
