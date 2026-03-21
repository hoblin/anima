# frozen_string_literal: true

module Mneme
  # Builds a compressed viewport for Mneme's LLM context. Mneme sees
  # conversation (user/agent messages and think events) but not mechanical
  # execution (tool calls and responses). Tool calls are compressed to
  # aggregate counters like `[4 tools called]`.
  #
  # The viewport is split into three zones separated by delimiters:
  # - **Eviction zone** — events about to leave the viewport (upper third)
  # - **Middle zone** — events in the middle of the viewport
  # - **Recent zone** — the most recent events (lower third)
  #
  # Zone boundaries are calculated WITH tool call tokens (they affect
  # position), then tool calls are removed and replaced with counters.
  #
  # @example
  #   viewport = Mneme::CompressedViewport.new(session, token_budget: 60_000)
  #   viewport.render  #=> "── EVICTION ZONE ──\nevent 42 User: ..."
  class CompressedViewport
    ZONE_DELIMITERS = {
      eviction: "── EVICTION ZONE (upper third) ──",
      middle: "── MIDDLE ZONE ──",
      recent: "── RECENT ZONE (lower third) ──"
    }.freeze

    # @param session [Session] the session to build viewport for
    # @param token_budget [Integer] total tokens available for Mneme's viewport
    # @param from_event_id [Integer, nil] start from this event ID (inclusive);
    #   when nil, uses the session's full viewport
    def initialize(session, token_budget:, from_event_id: nil)
      @session = session
      @token_budget = token_budget
      @from_event_id = from_event_id
    end

    # Renders the compressed viewport as a string ready for Mneme's LLM context.
    #
    # @return [String] compressed viewport with zone delimiters
    def render
      return "" if events.empty?

      zones = split_into_zones(events)
      render_zones(zones)
    end

    # @return [Array<Event>] the raw events selected for this viewport
    def events
      @events ||= fetch_events
    end

    private

    # Fetches events within token budget, starting from from_event_id.
    # Selects newest-first until budget exhausted, returns chronological.
    # Caches per-event token costs in @event_costs for reuse by split_into_zones.
    #
    # @return [Array<Event>]
    def fetch_events
      scope = @session.events.context_events.deliverable

      if @from_event_id
        scope = scope.where("id >= ?", @from_event_id)
      end

      selected = []
      @event_costs = {}
      remaining = @token_budget

      scope.reorder(id: :desc).each do |event|
        cost = event_token_cost(event)
        break if cost > remaining && selected.any?

        selected << event
        @event_costs[event.id] = cost
        remaining -= cost
      end

      selected.reverse
    end

    # Splits events into three zones by token count.
    # Zone boundaries are calculated including ALL events (tool calls count
    # toward position), but zone assignment uses cumulative tokens.
    #
    # @return [Hash{Symbol => Array<Event>}] :eviction, :middle, :recent
    def split_into_zones(events)
      costs = events.map { |event| [event, @event_costs[event.id] || event_token_cost(event)] }
      zone_size = costs.sum(&:last) / 3.0

      result = {eviction: [], middle: [], recent: []}
      cumulative = 0

      costs.each do |event, cost|
        cumulative += cost
        result[zone_for_cumulative(cumulative, zone_size)] << event
      end

      result
    end

    # Renders zones with delimiters, compressing tool calls into counters.
    #
    # @param zones [Hash{Symbol => Array<Event>}]
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

    # Renders a single zone: conversation events as full text, consecutive
    # tool calls/responses compressed into `[N tools called]` counters.
    # tool_response events are intentionally silent — they affect zone boundaries
    # via token cost but are not rendered; only tool_call events increment the counter.
    #
    # @param zone_events [Array<Event>]
    # @return [String]
    def render_zone(zone_events)
      lines = []
      tool_count = 0

      zone_events.each do |event|
        if conversation_event?(event) || think_event?(event)
          lines << flush_tool_count(tool_count)
          tool_count = 0
          lines << render_event_line(event)
        elsif event.event_type == "tool_call"
          tool_count += 1
        end
      end

      lines << flush_tool_count(tool_count)
      lines.compact.join("\n")
    end

    # @return [Boolean] true if event is a user/agent/system message
    def conversation_event?(event)
      event.event_type.in?(Event::CONVERSATION_TYPES)
    end

    # Think events are tool_call events with tool_name == "think".
    # They carry the agent's reasoning and are treated as conversation.
    #
    # @return [Boolean]
    def think_event?(event)
      event.event_type == "tool_call" && event.payload["tool_name"] == Event::THINK_TOOL
    end

    ROLE_LABELS = {
      "user_message" => "User",
      "agent_message" => "Assistant",
      "system_message" => "System"
    }.freeze

    # Renders a single event as a transcript line.
    #
    # @param event [Event]
    # @return [String]
    def render_event_line(event)
      prefix = "event #{event.id}"
      data = event.payload
      if think_event?(event)
        "#{prefix} Think: #{data.dig("tool_input", "thoughts")}"
      else
        "#{prefix} #{ROLE_LABELS.fetch(event.event_type)}: #{data["content"]}"
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
    def event_token_cost(event)
      cached = event.token_count
      (cached > 0) ? cached : event.estimate_tokens
    end
  end
end
