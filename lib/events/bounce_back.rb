# frozen_string_literal: true

module Events
  # Transient failure event emitted when LLM delivery fails inside the
  # Bounce Back transaction. The user event record is rolled back, and
  # this event notifies clients to remove the phantom message and
  # restore the text to the input field.
  #
  # Not persisted — not included in {Event::TYPES}.
  class BounceBack < Base
    TYPE = "bounce_back"

    # @return [String] human-readable error description
    attr_reader :error

    # @return [Integer, nil] database ID of the rolled-back event (for client-side removal)
    attr_reader :event_id

    # @param content [String] original user message text to restore to input
    # @param error [String] error description for the flash message
    # @param session_id [Integer] session the message was intended for
    # @param event_id [Integer, nil] ID of the event that was broadcast optimistically
    def initialize(content:, error:, session_id:, event_id: nil)
      super(content: content, session_id: session_id)
      @error = error
      @event_id = event_id
    end

    def type
      TYPE
    end

    def to_h
      super.merge(error: error, event_id: event_id)
    end
  end
end
