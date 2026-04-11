# frozen_string_literal: true

module Events
  # Emitted after a Message record is committed to the database.
  # Subscribers react to persisted messages — not to raw domain events.
  #
  # Carries the Message record directly so subscribers don't need to
  # look it up again.
  class MessageCreated
    TYPE = "message.created"

    attr_reader :message

    # @param message [Message] the persisted message record
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
