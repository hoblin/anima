# frozen_string_literal: true

module Events
  # Emitted by {MeleteEnrichmentJob} when goals changed during the Melete
  # run, signalling that Mneme should recall against the fresh goal set.
  # Mneme subscribes via {Events::Subscribers::MnemeKickoff}, performs
  # associative recall, enqueues its memories as background PendingMessages,
  # and emits {Events::StartProcessing} to continue the drain.
  #
  # Second stage of the +start_melete → (start_mneme) → start_processing+
  # chain. Conditional — when goals are untouched the pipeline jumps
  # straight from {Events::StartMelete} to {Events::StartProcessing}.
  class StartMneme
    TYPE = "session.start_mneme"

    attr_reader :session_id, :pending_message_id

    # @param session_id [Integer] session whose drain pipeline should start
    # @param pending_message_id [Integer] the PendingMessage that triggered the chain
    def initialize(session_id:, pending_message_id:)
      @session_id = session_id
      @pending_message_id = pending_message_id
    end

    def event_name
      "#{Bus::NAMESPACE}.#{TYPE}"
    end

    def to_h
      {type: TYPE, session_id:, pending_message_id:}
    end
  end
end
