# frozen_string_literal: true

module Events
  module Subscribers
    # Entry subscriber for the Mneme stage of the drain pipeline. On
    # {Events::StartMneme}, enqueues {MnemeEnrichmentJob} to run
    # associative recall asynchronously.
    class MnemeKickoff
      include Events::Subscriber

      # @param event [Hash] Rails.event notification hash
      def emit(event)
        payload = event[:payload]
        session_id = payload[:session_id]
        return unless session_id

        MnemeEnrichmentJob.perform_later(
          session_id,
          pending_message_id: payload[:pending_message_id]
        )
      end
    end
  end
end
