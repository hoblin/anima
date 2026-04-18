# frozen_string_literal: true

module Events
  # Emitted when a session's transport-level state changes. Carries the
  # AASM state after a transition (+"idle"+/+"awaiting"+/+"executing"+)
  # or a transient UI signal (+"interrupting"+).
  #
  # Subscribers broadcast the state over ActionCable so the TUI spinner
  # and sub-agent HUD update in sync.
  class SessionStateChanged
    TYPE = "session.state_changed"

    attr_reader :session_id, :state

    # @param session_id [Integer] the session the state change belongs to
    # @param state [String] transport state name
    def initialize(session_id:, state:)
      @session_id = session_id
      @state = state
    end

    def event_name
      "#{Bus::NAMESPACE}.#{TYPE}"
    end

    def to_h
      {type: TYPE, session_id: session_id, state: state}
    end
  end
end
