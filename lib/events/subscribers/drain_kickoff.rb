# frozen_string_literal: true

module Events
  module Subscribers
    # Entry subscriber for the drain loop. On {Events::StartProcessing},
    # enqueues {DrainJob} — the actual work (session claim, PM promotion,
    # LLM call) happens in the job so the emitter's thread isn't blocked.
    class DrainKickoff
      include Events::Subscriber

      # @param event [Hash] Rails.event notification hash
      def emit(event)
        session_id = event[:payload][:session_id]
        return unless session_id

        DrainJob.perform_later(session_id)
      end
    end
  end
end
