# frozen_string_literal: true

module Events
  # Emitted when Mneme finishes enriching context with recalled memories.
  # Melete subscribes and performs its own enrichment — activating skills,
  # evaluating goals, renaming the session — before yielding to the drain
  # loop via {Events::StartProcessing}.
  #
  # Second stage of the +start_mneme → start_melete → start_processing+
  # chain that orchestrates context enrichment before the LLM is called.
  class StartMelete
    TYPE = "session.start_melete"

    attr_reader :session_id, :pending_message_id

    # @param session_id [Integer] session whose enrichment chain should continue
    # @param pending_message_id [Integer, nil] the PendingMessage that triggered the chain
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
