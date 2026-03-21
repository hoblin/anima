# frozen_string_literal: true

module TUI
  # Thread-safe in-memory store for chat entries displayed in the TUI.
  # Replaces {Events::Subscribers::MessageCollector} in the WebSocket-based
  # TUI, with no dependency on Rails or the Events module.
  #
  # Accepts Action Cable event payloads and stores typed entries:
  # - `{type: :rendered, data:, event_type:, id:}` for events with structured decorator output
  # - `{type: :message, role:, content:, id:}` for user/agent messages (fallback)
  # - `{type: :tool_counter, calls:, responses:}` for tool activity
  #
  # Structured data takes priority when available. Events with nil
  # rendered content fall back to existing behavior: tool events aggregate
  # into counters, messages store role and content.
  #
  # Tool counters aggregate per agent turn: a new counter starts when a
  # tool_call arrives after a message entry. Consecutive tool events
  # increment the same counter until the next message breaks the chain.
  #
  # When an event arrives with `"action" => "update"` and a known `"id"`,
  # the existing entry is replaced in-place, preserving display order.
  class MessageStore
    MESSAGE_TYPES = %w[user_message agent_message].freeze

    ROLE_MAP = {
      "user_message" => "user",
      "agent_message" => "assistant"
    }.freeze

    def initialize
      @entries = []
      @entries_by_id = {}
      @mutex = Mutex.new
      @version = 0
    end

    # Monotonically increasing counter that bumps on every mutation.
    # Consumers compare this to a cached value to detect changes
    # without copying the full entries array on every frame.
    # @return [Integer]
    def version
      @mutex.synchronize { @version }
    end

    # @return [Array<Hash>] thread-safe copy of stored entries
    def messages
      @mutex.synchronize { @entries.dup }
    end

    # @return [Integer] number of stored entries (no array copy)
    def size
      @mutex.synchronize { @entries.size }
    end

    # Processes a raw event payload from the WebSocket channel.
    # Uses structured decorator data when available; falls back to
    # role/content extraction for messages and tool counter aggregation.
    #
    # Events with `"action" => "update"` and a matching `"id"` replace
    # the existing entry's data in-place rather than appending.
    #
    # @param event_data [Hash] Action Cable event payload with "type", "content",
    #   and optionally "rendered" (hash of mode => lines), "id", "action"
    # @return [Boolean] true if the event type was recognized and handled
    def process_event(event_data)
      event_id = event_data["id"]

      if event_data["action"] == "update" && event_id
        return update_existing(event_data, event_id)
      end

      rendered = extract_rendered(event_data)

      if rendered
        record_rendered(rendered, event_type: event_data["type"], id: event_id)
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
      @mutex.synchronize do
        @entries = []
        @entries_by_id = {}
        @version += 1
      end
    end

    # Returns the last pending user message for recall editing.
    # Walks entries backwards and returns the first pending user_message found.
    #
    # @return [Hash, nil] `{id: Integer, content: String}` or nil if none pending
    def last_pending_user_message
      @mutex.synchronize do
        @entries.reverse_each do |entry|
          next unless entry[:event_type] == "user_message"

          if entry[:type] == :rendered && entry.dig(:data, "status") == "pending"
            return {id: entry[:id], content: entry.dig(:data, "content")}
          end

          # Only check the most recent user message
          break
        end
        nil
      end
    end

    # Removes an entry by its event ID. Used when a pending message is
    # recalled for editing or deleted by another client.
    #
    # @param event_id [Integer] database ID of the event to remove
    # @return [Boolean] true if the entry was found and removed
    def remove_by_id(event_id)
      @mutex.synchronize do
        entry = @entries_by_id.delete(event_id)
        return false unless entry

        @entries.delete(entry)
        @version += 1
        true
      end
    end

    # Removes entries by their event IDs. Used when the brain reports
    # that events have left the LLM's viewport (context window eviction).
    # Acquires the mutex once for the entire batch.
    #
    # @param event_ids [Array<Integer>] database IDs of events to remove
    # @return [Integer] count of entries actually removed
    def remove_by_ids(event_ids)
      @mutex.synchronize do
        removed = 0
        event_ids.each do |event_id|
          entry = @entries_by_id.delete(event_id)
          next unless entry

          @entries.delete(entry)
          removed += 1
        end
        @version += 1 if removed > 0
        removed
      end
    end

    private

    # Replaces data on an existing entry matched by event ID.
    # Only updates rendered entries — tool counters and plain messages
    # are not individually addressable by ID.
    #
    # @return [Boolean] true if the entry was found and updated
    def update_existing(event_data, event_id)
      rendered = extract_rendered(event_data)
      return false unless rendered

      @mutex.synchronize do
        entry = @entries_by_id[event_id]
        return false unless entry

        entry[:data] = rendered
        @version += 1
        true
      end
    end

    # Extracts the first non-nil structured data hash from the rendered payload.
    # The "rendered" hash is keyed by view mode — the server includes only the
    # session's current mode, so there is always at most one entry.
    # (e.g. {"basic" => {"role" => "user", ...}} or {"basic" => nil} for hidden events)
    #
    # @return [Hash, nil] structured event data, or nil if not present
    def extract_rendered(event_data)
      event_data.dig("rendered")&.values&.compact&.first
    end

    def record_rendered(data, event_type: nil, id: nil)
      @mutex.synchronize do
        entry = {type: :rendered, data: data, event_type: event_type, id: id}
        @entries << entry
        @entries_by_id[id] = entry if id
        @version += 1
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
        @version += 1
      end
      true
    end

    def record_tool_response
      @mutex.synchronize do
        current = current_tool_counter
        return false unless current

        current[:responses] += 1
        @version += 1
      end
      true
    end

    def record_message(event_data)
      content = event_data["content"]
      return false if content.nil?

      event_id = event_data["id"]

      @mutex.synchronize do
        entry = {type: :message, role: ROLE_MAP.fetch(event_data["type"]), content: content, id: event_id}
        @entries << entry
        @entries_by_id[event_id] = entry if event_id
        @version += 1
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
