# frozen_string_literal: true

module Events
  # Emitted after a Message record is updated and committed.
  # Used by subscribers that need to react to message changes
  # (e.g. broadcasting updated token counts to WebSocket clients).
  class MessageUpdated
    TYPE = "message.updated"

    attr_reader :message

    # @param message [Message] the updated message record
    def initialize(message)
      @message = message
    end

    def event_name
      "#{Bus::NAMESPACE}.#{TYPE}"
    end

    def to_h
      {type: TYPE, message:}
    end
  end
end
