# frozen_string_literal: true

module TUI
  # Thread-safe in-memory store for chat entries displayed in the TUI.
  # Replaces {Events::Subscribers::MessageCollector} in the WebSocket-based
  # TUI, with no dependency on Rails or the Events module.
  #
  # Accepts Action Cable message payloads and stores typed entries:
  # - `{type: :rendered, data:, message_type:, id:}` for messages with structured decorator output
  # - `{type: :message, role:, content:, id:}` for user/agent messages (fallback)
  # - `{type: :tool_counter, calls:, responses:}` for tool activity
  #
  # Structured data takes priority when available. Messages with nil
  # rendered content fall back to existing behavior: tool messages aggregate
  # into counters, conversation messages store role and content.
  #
  # Entries with message IDs are maintained in ID order (ascending)
  # regardless of arrival order, preventing misordering from race
  # conditions between live broadcasts and viewport replays.
  # Duplicate IDs are deduplicated by updating the existing entry.
  #
  # Tool counters aggregate per agent turn: a new counter starts when a
  # tool_call arrives after a conversation entry. Consecutive tool messages
  # increment the same counter until the next conversation message breaks the chain.
  #
  # When a message arrives with `"action" => "update"` and a known `"id"`,
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
      message_id = event_data["id"]

      if event_data["action"] == "update" && message_id
        return update_existing(event_data, message_id)
      end

      rendered = extract_rendered(event_data)

      if rendered
        record_rendered(rendered, message_type: event_data["type"], id: message_id)
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
    # to prepare for re-decorated viewport messages from the server.
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
          next unless entry[:message_type] == "user_message"

          if entry[:type] == :rendered && entry.dig(:data, "status") == "pending"
            return {id: entry[:id], content: entry.dig(:data, "content")}
          end

          # Only check the most recent user message
          break
        end
        nil
      end
    end

    # Removes an entry by its message ID. Used when a pending message is
    # recalled for editing or deleted by another client.
    #
    # @param message_id [Integer] database ID of the message to remove
    # @return [Boolean] true if the entry was found and removed
    def remove_by_id(message_id)
      @mutex.synchronize do
        entry = @entries_by_id.delete(message_id)
        return false unless entry

        @entries.delete(entry)
        @version += 1
        true
      end
    end

    # Removes entries by their message IDs. Used when the brain reports
    # that messages have left the LLM's viewport (context window eviction).
    # Acquires the mutex once for the entire batch.
    #
    # @param message_ids [Array<Integer>] database IDs of messages to remove
    # @return [Integer] count of entries actually removed
    def remove_by_ids(message_ids)
      @mutex.synchronize do
        removed = 0
        message_ids.each do |message_id|
          entry = @entries_by_id.delete(message_id)
          next unless entry

          @entries.delete(entry)
          removed += 1
        end
        @version += 1 if removed > 0
        removed
      end
    end

    private

    # Replaces data on an existing entry matched by message ID.
    # Only updates rendered entries — tool counters and plain messages
    # are not individually addressable by ID.
    #
    # @return [Boolean] true if the entry was found and updated
    def update_existing(event_data, message_id)
      rendered = extract_rendered(event_data)
      return false unless rendered

      @mutex.synchronize do
        entry = @entries_by_id[message_id]
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

    # Inserts a rendered entry at the correct chronological position.
    # System prompt entries (no ID) are always placed at position 0.
    def record_rendered(data, message_type: nil, id: nil)
      @mutex.synchronize do
        entry = {type: :rendered, data: data, message_type: message_type, id: id}
        insert_ordered(entry)
        @version += 1
      end
      true
    end

    # Inserts an entry in message-ID order. Entries without an ID are
    # appended. If an entry with the same ID already exists, updates
    # it in-place (deduplication for live/viewport replay races).
    # System prompt uses ID 0, placing it before all positive-ID messages
    # and updating in-place on subsequent broadcasts.
    #
    # @param entry [Hash] the entry to insert
    # @return [void]
    def insert_ordered(entry)
      id = entry[:id]
      unless id
        @entries << entry
        return
      end

      existing = @entries_by_id[id]
      if existing
        existing[:data] = entry[:data] if entry.key?(:data)
        existing[:content] = entry[:content] if entry.key?(:content)
        existing[:message_type] = entry[:message_type] if entry.key?(:message_type)
        return
      end

      insert_sorted_by_id(entry)
      @entries_by_id[id] = entry
    end

    # Inserts an entry in sorted order by message ID. Optimized for the
    # common case where messages arrive in order (appends without scanning).
    # Entries without IDs (tool counters, etc.) are skipped during the
    # sort scan and don't affect insertion position.
    #
    # @param entry [Hash] entry with a non-nil +:id+
    # @return [void]
    def insert_sorted_by_id(entry)
      id = entry[:id]

      # Fast path: entry belongs at the end (typical during live streaming)
      last_id = last_entry_id
      if last_id.nil? || last_id < id
        @entries << entry
        return
      end

      # Out-of-order arrival: insert before the first entry with a higher ID
      insert_pos = @entries.index { |e| e[:id] && e[:id] > id } || @entries.size
      @entries.insert(insert_pos, entry)
    end

    # Returns the highest message ID in the entries array, scanning from the
    # end for efficiency (entries with IDs are typically at the tail).
    #
    # @return [Integer, nil] the highest message ID, or nil if no entries have IDs
    def last_entry_id
      @entries.reverse_each { |e| return e[:id] if e[:id] }
      nil
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

      @mutex.synchronize do
        entry = {type: :message, role: ROLE_MAP.fetch(event_data["type"]), content: content, id: event_data["id"]}
        insert_ordered(entry)
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
