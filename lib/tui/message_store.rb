# frozen_string_literal: true

module TUI
  # Thread-safe in-memory store for raw event payloads displayed in the TUI.
  # Stores Action Cable event payloads as-is for all context event types.
  # Presentation logic (role mapping, type filtering, tool counter aggregation)
  # is handled by {EventDecorator} subclasses and the rendering layer.
  class MessageStore
    CONTEXT_TYPES = %w[user_message agent_message tool_call tool_response].freeze

    MESSAGE_TYPES = %w[user_message agent_message].freeze

    def initialize
      @entries = []
      @mutex = Mutex.new
    end

    # @return [Array<Hash>] thread-safe copy of stored event payloads
    def messages
      @mutex.synchronize { @entries.dup }
    end

    # Stores a raw event payload from the WebSocket channel.
    # Only context event types (messages and tool interactions) are stored;
    # system messages and unknown types are ignored.
    # Message events with nil content are rejected (tool events are always stored).
    #
    # @param event_data [Hash] Action Cable event payload with "type" and "content"
    # @return [Boolean] true if the event type was recognized and stored
    def process_event(event_data)
      type = event_data["type"]
      return false unless storable?(type, event_data["content"])

      @mutex.synchronize { @entries << event_data }
      true
    end

    def clear
      @mutex.synchronize { @entries = [] }
    end

    private

    # @return [Boolean] true if the event should be stored
    def storable?(type, content)
      return false unless CONTEXT_TYPES.include?(type)
      return content.is_a?(String) if MESSAGE_TYPES.include?(type)

      true
    end
  end
end
