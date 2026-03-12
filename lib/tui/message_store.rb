# frozen_string_literal: true

module TUI
  # Thread-safe in-memory store for chat entries displayed in the TUI.
  # Replaces {Events::Subscribers::MessageCollector} in the WebSocket-based
  # TUI, with no dependency on Rails or the Events module.
  #
  # Accepts Action Cable event payloads and stores typed entries:
  # - `{type: :message, role:, content:}` for user/agent messages
  # - `{type: :tool_counter, calls:, responses:}` for tool activity
  class MessageStore
    MESSAGE_TYPES = %w[user_message agent_message].freeze

    ROLE_MAP = {
      "user_message" => "user",
      "agent_message" => "assistant"
    }.freeze

    def initialize
      @entries = []
      @mutex = Mutex.new
    end

    # @return [Array<Hash>] thread-safe copy of stored entries
    def messages
      @mutex.synchronize { @entries.dup }
    end

    # Processes a raw event payload from the WebSocket channel.
    # Stores user/agent messages and tracks tool call/response counts.
    #
    # @param event_data [Hash] Action Cable event payload with "type" and "content"
    # @return [Boolean] true if the event was processed
    def process_event(event_data)
      case event_data["type"]
      when "tool_call" then record_tool_call
      when "tool_response" then record_tool_response
      when *MESSAGE_TYPES then record_message(event_data)
      else false
      end
    end

    def clear
      @mutex.synchronize { @entries = [] }
    end

    private

    def record_tool_call
      @mutex.synchronize do
        current = current_tool_counter
        if current
          current[:calls] += 1
        else
          @entries << {type: :tool_counter, calls: 1, responses: 0}
        end
      end
      true
    end

    def record_tool_response
      @mutex.synchronize do
        current = current_tool_counter
        current[:responses] += 1 if current
      end
      true
    end

    def record_message(event_data)
      content = event_data["content"]
      return false if content.nil?

      @mutex.synchronize do
        @entries << {type: :message, role: ROLE_MAP.fetch(event_data["type"]), content: content}
      end
      true
    end

    # @return [Hash, nil] the last entry if it is a tool counter
    def current_tool_counter
      last = @entries.last
      last if last&.dig(:type) == :tool_counter
    end
  end
end
