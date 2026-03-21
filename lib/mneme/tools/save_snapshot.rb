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

      def self.description = "Save a summary of the conversation context " \
        "that is about to leave the viewport. Write a concise summary " \
        "capturing key decisions, topics discussed, and important context. " \
        "Focus on WHAT was decided and WHY, not mechanical details."

      def self.input_schema
        {
          type: "object",
          properties: {
            text: {
              type: "string",
              description: "The summary text. Be concise but preserve key decisions, " \
                "goals discussed, and important context. Max #{Anima::Settings.mneme_max_tokens} tokens."
            }
          },
          required: %w[text]
        }
      end

      # @param main_session [Session] the session being observed
      # @param from_event_id [Integer] first event ID covered by this snapshot
      # @param to_event_id [Integer] last event ID covered by this snapshot
      def initialize(main_session:, from_event_id:, to_event_id:, **)
        @main_session = main_session
        @from_event_id = from_event_id
        @to_event_id = to_event_id
      end

      def execute(input)
        text = input["text"].to_s.strip
        return {error: "Summary text cannot be blank"} if text.empty?

        snapshot = @main_session.snapshots.create!(
          text: text,
          from_event_id: @from_event_id,
          to_event_id: @to_event_id,
          level: 1,
          token_count: estimate_tokens(text)
        )

        "Snapshot saved (id: #{snapshot.id}, events #{@from_event_id}..#{@to_event_id})"
      end

      private

      # @return [Integer] estimated token count for the summary text
      def estimate_tokens(text)
        [(text.bytesize / Event::BYTES_PER_TOKEN.to_f).ceil, 1].max
      end
    end
  end
end
