# frozen_string_literal: true

module Events
  # Emitted when a +user_message+ PendingMessage lands on an idle session.
  # Melete subscribes via {Events::Subscribers::MeleteKickoff} and runs
  # its enrichment loop — activating skills, reading workflows, refining
  # goals, renaming the session — then either:
  #
  # * emits {Events::StartMneme} when a goal changed during the run, so
  #   Mneme can recall against the fresh goal set, or
  # * emits {Events::StartProcessing} when goals were untouched, skipping
  #   Mneme entirely (no new search seed to recall against).
  #
  # First stage of the +start_melete → (start_mneme) → start_processing+
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
