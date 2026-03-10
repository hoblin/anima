# frozen_string_literal: true

module TUI
  # Thread-safe in-memory store for chat messages displayed in the TUI.
  # Replaces {Events::Subscribers::MessageCollector} in the WebSocket-based
  # TUI, with no dependency on Rails or the Events module.
  #
  # Accepts Action Cable event payloads and extracts displayable messages.
  class MessageStore
    DISPLAYABLE_TYPES = %w[user_message agent_message].freeze

    ROLE_MAP = {
      "user_message" => "user",
      "agent_message" => "assistant"
    }.freeze

    def initialize
      @messages = []
      @mutex = Mutex.new
    end

    # @return [Array<Hash>] thread-safe copy of collected messages
    def messages
      @mutex.synchronize { @messages.dup }
    end

    # Processes a raw event payload from the WebSocket channel.
    # Only user_message and agent_message events are stored.
    #
    # @param event_data [Hash] Action Cable event payload with "type" and "content"
    # @return [Boolean] true if the message was stored
    def process_event(event_data)
      type = event_data["type"]
      return false unless DISPLAYABLE_TYPES.include?(type)

      content = event_data["content"]
      return false if content.nil?

      @mutex.synchronize do
        @messages << {role: ROLE_MAP.fetch(type), content: content}
      end
      true
    end

    def clear
      @mutex.synchronize { @messages = [] }
    end
  end
end
