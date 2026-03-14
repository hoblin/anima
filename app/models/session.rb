# frozen_string_literal: true

# A conversation session — the fundamental unit of agent interaction.
# Owns an ordered stream of {Event} records representing everything
# that happened: user messages, agent responses, tool calls, etc.
#
# Sessions form a hierarchy: a main session can spawn child sessions
# (sub-agents) that inherit the parent's viewport context at fork time.
class Session < ApplicationRecord
  # Claude Sonnet 4 context window minus system prompt reserve.
  DEFAULT_TOKEN_BUDGET = 190_000

  VIEW_MODES = %w[basic verbose debug].freeze

  serialize :granted_tools, coder: JSON

  has_many :events, -> { order(:id) }, dependent: :destroy

  belongs_to :parent_session, class_name: "Session", optional: true
  has_many :child_sessions, class_name: "Session", foreign_key: :parent_session_id, dependent: :destroy

  validates :view_mode, inclusion: {in: VIEW_MODES}

  scope :recent, ->(limit = 10) { order(updated_at: :desc).limit(limit) }
  scope :root_sessions, -> { where(parent_session_id: nil) }

  # Cycles to the next view mode: basic → verbose → debug → basic.
  #
  # @return [String] the next view mode in the cycle
  def next_view_mode
    current_index = VIEW_MODES.index(view_mode) || 0
    VIEW_MODES[(current_index + 1) % VIEW_MODES.size]
  end

  # @return [Boolean] true if this session is a sub-agent (has a parent)
  def sub_agent?
    parent_session_id.present?
  end

  # Returns the events currently visible in the LLM context window.
  # Walks events newest-first and includes them until the token budget
  # is exhausted. Events are full-size or excluded entirely.
  #
  # Sub-agent sessions inherit parent context via virtual viewport:
  # child events are prioritized and fill the budget first (newest-first),
  # then parent events from before the fork point fill the remaining budget.
  # The final array is chronological: parent events first, then child events.
  #
  # @param token_budget [Integer] maximum tokens to include (positive)
  # @param include_pending [Boolean] whether to include pending messages (true for
  #   display, false for LLM context assembly)
  # @return [Array<Event>] chronologically ordered
  def viewport_events(token_budget: DEFAULT_TOKEN_BUDGET, include_pending: true)
    own_events = select_events(own_event_scope(include_pending), budget: token_budget)
    remaining = token_budget - own_events.sum { |e| event_token_cost(e) }

    if sub_agent? && remaining > 0
      parent_events = select_events(parent_event_scope(include_pending), budget: remaining)
      trim_trailing_tool_calls(parent_events) + own_events
    else
      own_events
    end
  end

  # Returns the system prompt for this session.
  # Sub-agent sessions use their stored prompt. Main sessions return nil
  # (system prompt assembly by Soul/Identity is not yet implemented).
  #
  # @return [String, nil] the system prompt text, or nil for main sessions
  def system_prompt
    prompt
  end

  # Builds the message array expected by the Anthropic Messages API.
  # Includes user/agent messages and tool call/response events in
  # Anthropic's wire format. Consecutive tool_call events are grouped
  # into a single assistant message; consecutive tool_response events
  # are grouped into a single user message with tool_result blocks.
  # Pending messages are excluded — they haven't been delivered yet.
  #
  # @param token_budget [Integer] maximum tokens to include (positive)
  # @return [Array<Hash>] Anthropic Messages API format
  def messages_for_llm(token_budget: DEFAULT_TOKEN_BUDGET)
    assemble_messages(viewport_events(token_budget: token_budget, include_pending: false))
  end

  # Promotes all pending user messages to delivered status so they
  # appear in the next LLM context. Triggers broadcast_update for
  # each event so connected clients refresh the pending indicator.
  #
  # @return [Integer] number of promoted messages
  def promote_pending_messages!
    promoted = 0
    events.where(event_type: "user_message", status: Event::PENDING_STATUS).find_each do |event|
      event.update!(status: nil, payload: event.payload.except("status"))
      promoted += 1
    end
    promoted
  end

  private

  # Scopes own events for viewport assembly.
  # @return [ActiveRecord::Relation]
  def own_event_scope(include_pending)
    scope = events.context_events
    include_pending ? scope : scope.deliverable
  end

  # Scopes parent events created before this session's fork point.
  # @return [ActiveRecord::Relation]
  def parent_event_scope(include_pending)
    scope = parent_session.events.context_events.where(created_at: ...created_at)
    include_pending ? scope : scope.deliverable
  end

  # Walks events newest-first, selecting until the token budget is exhausted.
  # Always includes at least the newest event even if it exceeds budget.
  #
  # @param scope [ActiveRecord::Relation] event scope to select from
  # @param budget [Integer] maximum tokens to include
  # @return [Array<Event>] chronologically ordered
  def select_events(scope, budget:)
    selected = []
    remaining = budget

    scope.reorder(id: :desc).each do |event|
      cost = event_token_cost(event)
      break if cost > remaining && selected.any?

      selected << event
      remaining -= cost
    end

    selected.reverse
  end

  # @return [Integer] token cost, using cached count or heuristic estimate
  def event_token_cost(event)
    (event.token_count > 0) ? event.token_count : estimate_tokens(event)
  end

  # Removes trailing tool_call events that lack matching tool_response.
  # Prevents orphaned tool_use blocks at the parent/child viewport boundary
  # (the spawn_subagent tool_call is emitted before the child session exists,
  # but its tool_response comes after — so the cutoff can split them).
  def trim_trailing_tool_calls(event_list)
    event_list.pop while event_list.last&.event_type == "tool_call"
    event_list
  end

  # Converts a chronological list of events into Anthropic wire-format messages.
  # Groups consecutive tool_call events into one assistant message and
  # consecutive tool_response events into one user message.
  #
  # @param events [Array<Event>]
  # @return [Array<Hash>]
  def assemble_messages(events)
    events.each_with_object([]) do |event, messages|
      case event.event_type
      when "user_message"
        messages << {role: "user", content: event.payload["content"].to_s}
      when "agent_message"
        messages << {role: "assistant", content: event.payload["content"].to_s}
      when "tool_call"
        append_grouped_block(messages, "assistant", tool_use_block(event.payload))
      when "tool_response"
        append_grouped_block(messages, "user", tool_result_block(event.payload))
      end
    end
  end

  # Groups consecutive tool blocks into a single message of the given role.
  def append_grouped_block(messages, role, block)
    prev = messages.last
    if prev&.dig(:role) == role && prev[:content].is_a?(Array)
      prev[:content] << block
    else
      messages << {role: role, content: [block]}
    end
  end

  def tool_use_block(payload)
    {
      type: "tool_use",
      id: payload["tool_use_id"],
      name: payload["tool_name"],
      input: payload["tool_input"] || {}
    }
  end

  def tool_result_block(payload)
    {
      type: "tool_result",
      tool_use_id: payload["tool_use_id"],
      content: payload["content"].to_s
    }
  end

  # Delegates to {Event#estimate_tokens} for events not yet counted
  # by the background job.
  #
  # @param event [Event]
  # @return [Integer] at least 1
  def estimate_tokens(event)
    event.estimate_tokens
  end
end
