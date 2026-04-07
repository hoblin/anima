# frozen_string_literal: true

module Events
  # Emitted after Mneme advances the boundary past an eviction zone.
  # Subscribers broadcast the cutoff to connected clients so they can
  # drop messages below it.
  class EvictionCompleted
    TYPE = "eviction.completed"

    attr_reader :session_id, :evict_above_id

    # @param session_id [Integer] the session whose boundary advanced
    # @param evict_above_id [Integer] last message ID in the evicted zone;
    #   clients drop all messages with id <= this value
    def initialize(session_id:, evict_above_id:)
      @session_id = session_id
      @evict_above_id = evict_above_id
    end

    def event_name
      "#{Bus::NAMESPACE}.#{TYPE}"
    end

    def to_h
      {type: TYPE, session_id:, evict_above_id:}
    end
  end
end
