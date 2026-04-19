# frozen_string_literal: true

require_relative "settings"

module TUI
  # Thread-safe in-memory store for chat entries displayed in the TUI.
  # Holds the WebSocket-delivered view of the session's conversation with
  # no dependency on Rails or the Events module.
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
      @pending_entries = []
      @pending_by_id = {}
      @mutex = Mutex.new
      @version = 0
      @token_economy = default_token_economy
    end

    # Monotonically increasing counter that bumps on every mutation.
    # Consumers compare this to a cached value to detect changes
    # without copying the full entries array on every frame.
    # @return [Integer]
    def version
      @mutex.synchronize { @version }
    end

    # @return [Array<Hash>] thread-safe copy of stored entries (pending messages at the end)
    def messages
      @mutex.synchronize { @entries.dup + @pending_entries.dup }
    end

    # @return [Integer] number of stored entries including pending (no array copy)
    def size
      @mutex.synchronize { @entries.size + @pending_entries.size }
    end

    # Returns aggregated token economy data for HUD display.
    # Includes running totals, cache hit rate, and latest rate limit snapshot.
    #
    # @return [Hash] token economy stats:
    #   - :input_tokens [Integer] total input tokens across all calls
    #   - :output_tokens [Integer] total output tokens
    #   - :cache_read_input_tokens [Integer] total cached token reads
    #   - :cache_creation_input_tokens [Integer] total cache writes
    #   - :call_count [Integer] number of API calls tracked
    #   - :cache_hit_rate [Float] percentage of input served from cache (0.0-1.0)
    #   - :rate_limits [Hash, nil] latest rate limit values from API
    def token_economy
      @mutex.synchronize do
        stats = @token_economy.dup
        total_input = stats[:input_tokens] + stats[:cache_read_input_tokens] + stats[:cache_creation_input_tokens]
        stats[:cache_hit_rate] = if total_input > 0
          stats[:cache_read_input_tokens].to_f / total_input
        else
          0.0
        end
        stats
      end
    end

    # Processes a raw event payload from the WebSocket channel.
    # Uses structured decorator data when available; falls back to
    # role/content extraction for messages and tool counter aggregation.
    #
    # Events with `"action" => "update"` and a matching `"id"` replace
    # the existing entry's data in-place rather than appending.
    #
    # Extracts api_metrics when present and accumulates token economy data.
    #
    # @param event_data [Hash] Action Cable event payload with "type", "content",
    #   and optionally "rendered" (hash of mode => lines), "id", "action", "api_metrics"
    # @return [Boolean] true if the event type was recognized and handled
    def process_event(event_data)
      message_id = event_data["id"]

      # Track API metrics for token economy HUD (only on create, not update)
      if event_data["action"] != "update"
        accumulate_api_metrics(event_data["api_metrics"])
      end

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
    # Resets token economy totals since we're starting fresh.
    # @return [void]
    def clear
      @mutex.synchronize do
        @entries = []
        @entries_by_id = {}
        @pending_entries = []
        @pending_by_id = {}
        @token_economy = default_token_economy
        @version += 1
      end
    end

    # Adds a pending message to the separate pending list.
    # Pending messages always render after real messages.
    #
    # @param pending_message_id [Integer] PendingMessage database ID
    # @param content [String] message text
    # @return [void]
    def add_pending(pending_message_id, content)
      @mutex.synchronize do
        entry = {
          type: :rendered,
          data: {"role" => "user", "content" => content, "status" => "pending"},
          message_type: "user_message",
          pending_message_id: pending_message_id
        }
        old = @pending_by_id[pending_message_id]
        @pending_entries.delete(old) if old
        @pending_entries << entry
        @pending_by_id[pending_message_id] = entry
        @version += 1
      end
    end

    # Removes a pending message by its PendingMessage ID.
    #
    # @param pending_message_id [Integer] PendingMessage database ID
    # @return [Boolean] true if found and removed
    def remove_pending(pending_message_id)
      @mutex.synchronize do
        entry = @pending_by_id.delete(pending_message_id)
        return false unless entry

        @pending_entries.delete(entry)
        @version += 1
        true
      end
    end

    # Returns the last pending user message for recall editing.
    #
    # @return [Hash, nil] `{pending_message_id: Integer, content: String}` or nil
    def last_pending_user_message
      @mutex.synchronize do
        entry = @pending_entries.last
        return nil unless entry

        {pending_message_id: entry[:pending_message_id], content: entry.dig(:data, "content")}
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

    # Removes all entries with message ID <= cutoff. Used when Mneme
    # evicts messages above the cutoff in the chat view (older messages
    # at the top with smaller IDs).
    #
    # @param cutoff_id [Integer] last evicted message ID
    # @return [Integer] count of entries actually removed
    def remove_above(cutoff_id)
      @mutex.synchronize do
        evicted = @entries.select { |e| e[:id] && e[:id] <= cutoff_id }
        evicted.each do |entry|
          @entries.delete(entry)
          @entries_by_id.delete(entry[:id])
        end
        @version += 1 if evicted.any?
        evicted.size
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
    # Callers send system prompt entries with {Message::SYSTEM_PROMPT_ID}
    # (0) so they sort before all positive-ID messages and deduplicate
    # on subsequent broadcasts.
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

    # Inserts an entry in sorted order by message ID. Optimized for two
    # common cases: appending (live streaming, ascending order) and
    # prepending (session history replay, descending/newest-first order).
    # Falls back to binary scan for out-of-order arrivals.
    #
    # Note: prepending N messages via +unshift+ is O(n) per call. For
    # large viewport replays this totals O(n²), acceptable at typical
    # viewport sizes (50–100 messages).
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

      # Fast path: entry belongs at the beginning (session history replay, newest-first).
      # Only safe when the first entry has an ID — non-ID entries (tool counters)
      # at the head would be displaced, so we fall through to the general path.
      first_id = @entries.first&.dig(:id)
      if first_id && id < first_id
        @entries.unshift(entry)
        return
      end

      # Out-of-order arrival: insert before the first entry with a higher ID
      insert_pos = @entries.index { |e| e[:id] && e[:id] > id } || @entries.size
      @entries.insert(insert_pos, entry)
    end

    # Returns the highest message ID in the entries array, scanning from the
    # end for efficiency (entries with IDs are typically at the tail).
    # Used by {#insert_sorted_by_id} to detect the append fast path.
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

    # Default token economy state for initialization and reset.
    # @return [Hash]
    def default_token_economy
      {
        input_tokens: 0,
        output_tokens: 0,
        cache_read_input_tokens: 0,
        cache_creation_input_tokens: 0,
        call_count: 0,
        rate_limits: nil,
        cache_history: []
      }
    end

    # Accumulates API metrics from a message into running totals.
    # Updates rate limits with the latest snapshot (most recent wins).
    #
    # @param api_metrics [Hash, nil] metrics from API response with "usage" and "rate_limits"
    # @return [void]
    def accumulate_api_metrics(api_metrics)
      return unless api_metrics.is_a?(Hash)

      @mutex.synchronize do
        usage = api_metrics["usage"]
        if usage.is_a?(Hash)
          input = usage["input_tokens"].to_i
          cache_read = usage["cache_read_input_tokens"].to_i
          cache_create = usage["cache_creation_input_tokens"].to_i

          @token_economy[:input_tokens] += input
          @token_economy[:output_tokens] += usage["output_tokens"].to_i
          @token_economy[:cache_read_input_tokens] += cache_read
          @token_economy[:cache_creation_input_tokens] += cache_create
          @token_economy[:call_count] += 1

          # Per-call cache hit rate for sparkline graph
          total = input + cache_read + cache_create
          hit_rate = (total > 0) ? cache_read.to_f / total : 0.0
          history = @token_economy[:cache_history]
          history.shift if history.size >= Settings.message_store_max_cache_history
          history << hit_rate
        end

        rate_limits = api_metrics["rate_limits"]
        if rate_limits.is_a?(Hash)
          @token_economy[:rate_limits] = rate_limits
        end

        @version += 1
      end
    end
  end
end
