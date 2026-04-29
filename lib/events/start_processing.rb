# frozen_string_literal: true

module Events
  # Emitted when an active PendingMessage lands on an idle session and does
  # not require the Melete/Mneme enrichment pipeline (tool calls, tool
  # responses, sub-agent replies), or when {MeleteEnrichmentJob} finishes
  # without a goal change, or when {MnemeEnrichmentJob} finishes recall.
  # The drain loop subscribes and begins processing the mailbox.
  #
  # Final stage of the +start_melete → (start_mneme) → start_processing+
  # chain.
  class StartProcessing
    TYPE = "session.start_processing"

    attr_reader :session_id, :pending_message_id

    # @param session_id [Integer] session whose drain loop should start
    # @param pending_message_id [Integer, nil] the PendingMessage that triggered the chain, if any
    def initialize(session_id:, pending_message_id: nil)
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
