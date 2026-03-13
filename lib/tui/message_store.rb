# frozen_string_literal: true

module TUI
  # Thread-safe in-memory store for chat entries displayed in the TUI.
  # Replaces {Events::Subscribers::MessageCollector} in the WebSocket-based
  # TUI, with no dependency on Rails or the Events module.
  #
  # Accepts Action Cable event payloads and stores typed entries:
  # - `{type: :rendered, data:, event_type:}` for events with structured decorator output
  # - `{type: :message, role:, content:}` for user/agent messages (fallback)
  # - `{type: :tool_counter, calls:, responses:}` for tool activity
  #
  # Structured data takes priority when available. Events with nil
  # rendered content fall back to existing behavior: tool events aggregate
  # into counters, messages store role and content.
  #
  # Tool counters aggregate per agent turn: a new counter starts when a
  # tool_call arrives after a message entry. Consecutive tool events
  # increment the same counter until the next message breaks the chain.
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
    # Uses pre-rendered decorator output when available; falls back to
    # role/content extraction for messages and tool counter aggregation.
    #
    # @param event_data [Hash] Action Cable event payload with "type", "content",
    #   and optionally "rendered" (hash of mode => lines)
    # @return [Boolean] true if the event type was recognized and handled
    def process_event(event_data)
      rendered = extract_rendered(event_data)

      if rendered
        record_rendered(rendered, event_type: event_data["type"])
      else
        case event_data["type"]
        when "tool_call" then record_tool_call
        when "tool_response" then record_tool_response
        when *MESSAGE_TYPES then record_message(event_data)
        else false
        end
      end
    end

    # Removes all entries. Called on view mode change and session switch
    # to prepare for re-decorated viewport events from the server.
    # @return [void]
    def clear
      @mutex.synchronize { @entries = [] }
    end

    private

    # Extracts the first non-nil structured data hash from the rendered payload.
    # The "rendered" hash is keyed by view mode — the server includes only the
    # session's current mode, so there is always at most one entry.
    # (e.g. {"basic" => {"role" => "user", ...}} or {"basic" => nil} for hidden events)
    #
    # @return [Hash, nil] structured event data, or nil if not present
    def extract_rendered(event_data)
      event_data.dig("rendered")&.values&.compact&.first
    end

    def record_rendered(data, event_type: nil)
      @mutex.synchronize do
        @entries << {type: :rendered, data: data, event_type: event_type}
      end
      true
    end

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
