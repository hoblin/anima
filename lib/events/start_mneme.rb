# frozen_string_literal: true

module Events
  # Emitted when a new +user_message+ or +think+ PendingMessage lands on an
  # idle session. Mneme subscribes and performs associative recall, then
  # enqueues its memories as background PendingMessages and emits
  # {Events::StartMelete} to continue the pipeline.
  #
  # First stage of the +start_mneme → start_melete → start_processing+
  # chain that orchestrates context enrichment before the LLM is called.
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
