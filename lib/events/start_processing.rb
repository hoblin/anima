# frozen_string_literal: true

module Events
  # Emitted when an active PendingMessage lands on an idle session and does
  # not require the Mneme/Melete enrichment pipeline (tool calls, tool
  # responses, sub-agent replies), or when Melete finishes the enrichment
  # chain. The drain loop subscribes and begins processing the mailbox.
  #
  # Final stage of the +start_mneme → start_melete → start_processing+
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
