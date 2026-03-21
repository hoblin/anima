# frozen_string_literal: true

module Events
  module Subscribers
    # Reacts to non-pending {Events::UserMessage} emissions by scheduling
    # {AgentRequestJob}. This is the event-driven bridge between the
    # channel (which emits the intent) and the job (which persists and
    # delivers the message).
    #
    # Pending messages are skipped — they are picked up by the running
    # agent loop after it finishes the current turn.
    class AgentDispatcher
      include Events::Subscriber

      # @param event [Hash] Rails.event notification hash
      def emit(event)
        payload = event[:payload]
        return unless payload.is_a?(Hash)
        return unless payload[:type] == "user_message"
        return if payload[:status] == Event::PENDING_STATUS

        session_id = payload[:session_id]
        return unless session_id

        AgentRequestJob.perform_later(session_id, content: payload[:content])
      end
    end
  end
end
