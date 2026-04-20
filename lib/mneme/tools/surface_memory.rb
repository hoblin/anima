# frozen_string_literal: true

module Mneme
  module Tools
    # Surfaces a past message into Aoide's next turn as a `from_mneme`
    # phantom tool pair. Called by Mneme's recall loop when a search hit
    # or a viewed message clears her relevance bar.
    #
    # The persisted {PendingMessage} carries the original +message_id+ in
    # its +source_name+ (and through promotion ends up inside
    # +tool_input.message_id+ of the phantom pair), so the same memory
    # isn't re-surfaced on later cycles — Mneme::Search already excludes
    # Aoide's viewport, and once a recall promotes it lives there.
    #
    # The muse explains +why+ she's surfacing this memory. The reason is
    # logged but not shown to Aoide — keeping the surfaced content itself
    # clean of meta-commentary.
    class SurfaceMemory < ::Tools::Base
      def self.tool_name = "surface_memory"

      def self.description = "Surface a memory into Aoide's next turn. Use when a specific past message is genuinely useful for what she's working on now. Pass the message_id and a short reason — one sentence explaining why she needs this *now*."

      def self.input_schema
        {
          type: "object",
          properties: {
            message_id: {type: "integer"},
            why: {type: "string", description: "One-sentence justification — kept for logs, not shown to Aoide."}
          },
          required: %w[message_id why]
        }
      end

      # @param main_session [Session] the session receiving the recall
      def initialize(main_session:, **)
        @main_session = main_session
      end

      def execute(input)
        message_id = input["message_id"].to_i
        why = input["why"].to_s.strip

        message = Message.find_by(id: message_id)
        return {error: "Message #{message_id} not found"} unless message
        return {error: "Reason cannot be blank"} if why.empty?

        content = render_snippet(message)

        @main_session.pending_messages.create!(
          content: content,
          source_type: "recall",
          source_name: message_id.to_s,
          message_type: "from_mneme"
        )

        Mneme.logger.info("session=#{@main_session.id} — surfaced message #{message_id}: #{why}")

        "Surfaced message #{message_id}."
      end

      private

      # Formats the message as the text Aoide will read when the phantom
      # pair promotes. Headed with origin metadata, bounded by the recall
      # snippet-token budget so long messages don't blow out her viewport.
      #
      # @param message [Message]
      # @return [String]
      def render_snippet(message)
        origin = message.session&.name.presence || "session ##{message.session_id}"
        raw = extract_content(message)
        max_chars = Anima::Settings.recall_max_snippet_tokens * TokenEstimation::BYTES_PER_TOKEN
        "message #{message.id} (#{origin}): #{raw.truncate(max_chars)}"
      end

      def extract_content(message)
        payload = message.payload
        case message.message_type
        when "user_message", "agent_message", "system_message"
          payload["content"].to_s
        when "tool_call"
          payload.dig("tool_input", "thoughts").to_s
        else
          payload["content"].to_s
        end
      end
    end
  end
end
