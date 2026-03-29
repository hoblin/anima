# frozen_string_literal: true

module Mneme
  # Builds a compressed viewport for Mneme's LLM context. Mneme sees
  # conversation (user/agent messages and think events) but not mechanical
  # execution (tool calls and responses). Tool calls are compressed to
  # aggregate counters like `[4 tools called]`.
  #
  # The viewport is split into three zones separated by delimiters:
  # - **Eviction zone** — messages about to leave the viewport (upper third)
  # - **Middle zone** — messages in the middle of the viewport
  # - **Recent zone** — the most recent messages (lower third)
  #
  # Zone boundaries are calculated WITH tool call tokens (they affect
  # position), then tool calls are removed and replaced with counters.
  #
  # @example
  #   viewport = Mneme::CompressedViewport.new(session, token_budget: 60_000)
  #   viewport.render  #=> "── EVICTION ZONE ──\nmessage 42 User: ..."
  class CompressedViewport
    ZONE_DELIMITERS = {
      eviction: "── EVICTION ZONE (upper third) ──",
      middle: "── MIDDLE ZONE ──",
      recent: "── RECENT ZONE (lower third) ──"
    }.freeze

    # @param session [Session] the session to build viewport for
    # @param token_budget [Integer] total tokens available for Mneme's viewport
    # @param from_message_id [Integer, nil] start from this message ID (inclusive);
    #   when nil, uses the session's full viewport
    def initialize(session, token_budget:, from_message_id: nil)
      @session = session
      @token_budget = token_budget
      @from_message_id = from_message_id
    end

    # Renders the compressed viewport as a string ready for Mneme's LLM context.
    #
    # @return [String] compressed viewport with zone delimiters
    def render
      return "" if messages.empty?

      zones = split_into_zones(messages)
      render_zones(zones)
    end

    # @return [Array<Message>] the raw messages selected for this viewport
    def messages
      @messages ||= fetch_messages
    end

    private

    # Fetches messages within token budget, starting from from_message_id.
    # Selects newest-first until budget exhausted, returns chronological.
    # Caches per-message token costs in @message_costs for reuse by split_into_zones.
    #
    # @return [Array<Message>]
    def fetch_messages
      scope = @session.messages.context_messages

      if @from_message_id
        scope = scope.where("id >= ?", @from_message_id)
      end

      selected = []
      @message_costs = {}
      remaining = @token_budget

      scope.reorder(id: :desc).each do |message|
        cost = message_token_cost(message)
        break if cost > remaining && selected.any?

        selected << message
        @message_costs[message.id] = cost
        remaining -= cost
      end

      selected.reverse
    end

    # Splits messages into three zones by token count.
    # Zone boundaries are calculated including ALL messages (tool calls count
    # toward position), but zone assignment uses cumulative tokens.
    #
    # @return [Hash{Symbol => Array<Message>}] :eviction, :middle, :recent
    def split_into_zones(messages)
      costs = messages.map { |message| [message, @message_costs[message.id] || message_token_cost(message)] }
      zone_size = costs.sum(&:last) / 3.0

      result = {eviction: [], middle: [], recent: []}
      cumulative = 0

      costs.each do |message, cost|
        cumulative += cost
        result[zone_for_cumulative(cumulative, zone_size)] << message
      end

      result
    end

    # Renders zones with delimiters, compressing tool calls into counters.
    #
    # @param zones [Hash{Symbol => Array<Message>}]
    # @return [String]
    def render_zones(zones)
      %i[eviction middle recent].flat_map { |name|
        [ZONE_DELIMITERS[name], render_zone(zones[name])]
      }.join("\n")
    end

    # Determines which zone an event belongs to based on cumulative token position.
    #
    # @param cumulative [Numeric] cumulative token count including this event
    # @param zone_size [Float] token count per zone (total / 3)
    # @return [Symbol] :eviction, :middle, or :recent
    def zone_for_cumulative(cumulative, zone_size)
      if cumulative <= zone_size
        :eviction
      elsif cumulative <= zone_size * 2
        :middle
      else
        :recent
      end
    end

    # Renders a single zone: conversation messages as full text, consecutive
    # tool calls/responses compressed into `[N tools called]` counters.
    # tool_response messages are intentionally silent — they affect zone boundaries
    # via token cost but are not rendered; only tool_call messages increment the counter.
    #
    # @param zone_messages [Array<Message>]
    # @return [String]
    def render_zone(zone_messages)
      lines = []
      tool_count = 0

      zone_messages.each do |message|
        if conversation_message?(message) || think_message?(message)
          lines << flush_tool_count(tool_count)
          tool_count = 0
          lines << render_message_line(message)
        elsif message.message_type == "tool_call"
          tool_count += 1
        end
      end

      lines << flush_tool_count(tool_count)
      lines.compact.join("\n")
    end

    # @return [Boolean] true if message is a user/agent/system message
    def conversation_message?(message)
      message.message_type.in?(Message::CONVERSATION_TYPES)
    end

    # Think messages are tool_call messages with tool_name == "think".
    # They carry the agent's reasoning and are treated as conversation.
    #
    # @return [Boolean]
    def think_message?(message)
      message.message_type == "tool_call" && message.payload["tool_name"] == Message::THINK_TOOL
    end

    ROLE_LABELS = {
      "user_message" => "User",
      "agent_message" => "Assistant",
      "system_message" => "System"
    }.freeze

    # Renders a single message as a transcript line.
    #
    # @param message [Message]
    # @return [String]
    def render_message_line(message)
      prefix = "message #{message.id}"
      data = message.payload
      if think_message?(message)
        "#{prefix} Think: #{data.dig("tool_input", "thoughts")}"
      else
        "#{prefix} #{ROLE_LABELS.fetch(message.message_type)}: #{data["content"]}"
      end
    end

    # Returns a tool count string if any tools were called, nil otherwise.
    #
    # @param count [Integer] number of tool calls to flush
    # @return [String, nil]
    def flush_tool_count(count)
      return if count == 0
      "[#{count} #{(count == 1) ? "tool" : "tools"} called]"
    end

    # @return [Integer] token cost using cached count or heuristic
    def message_token_cost(message)
      cached = message.token_count
      (cached > 0) ? cached : message.estimate_tokens
    end
  end
end
