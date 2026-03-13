# frozen_string_literal: true

# A conversation session — the fundamental unit of agent interaction.
# Owns an ordered stream of {Event} records representing everything
# that happened: user messages, agent responses, tool calls, etc.
class Session < ApplicationRecord
  # Claude Sonnet 4 context window minus system prompt reserve.
  DEFAULT_TOKEN_BUDGET = 190_000

  VIEW_MODES = %w[basic verbose debug].freeze

  has_many :events, -> { order(:id) }, dependent: :destroy

  validates :view_mode, inclusion: {in: VIEW_MODES}

  scope :recent, ->(limit = 10) { order(updated_at: :desc).limit(limit) }

  # Cycles to the next view mode: basic → verbose → debug → basic.
  #
  # @return [String] the next view mode in the cycle
  def next_view_mode
    current_index = VIEW_MODES.index(view_mode) || 0
    VIEW_MODES[(current_index + 1) % VIEW_MODES.size]
  end

  # Returns the events currently visible in the LLM context window.
  # Walks events newest-first and includes them until the token budget
  # is exhausted. Events are full-size or excluded entirely.
  #
  # @param token_budget [Integer] maximum tokens to include (positive)
  # @return [Array<Event>] chronologically ordered
  def viewport_events(token_budget: DEFAULT_TOKEN_BUDGET)
    selected = []
    remaining = token_budget

    events.context_events.reorder(id: :desc).each do |event|
      cost = (event.token_count > 0) ? event.token_count : estimate_tokens(event)
      break if cost > remaining && selected.any?

      selected << event
      remaining -= cost
    end

    selected.reverse
  end

  # Returns the assembled system prompt for this session.
  # The system prompt includes system instructions, goals, and memories.
  # Currently a placeholder — these subsystems are not yet implemented.
  #
  # @return [String, nil] the system prompt text, or nil if not configured
  def system_prompt
    nil
  end

  # Builds the message array expected by the Anthropic Messages API.
  # Includes user/agent messages and tool call/response events in
  # Anthropic's wire format. Consecutive tool_call events are grouped
  # into a single assistant message; consecutive tool_response events
  # are grouped into a single user message with tool_result blocks.
  #
  # @param token_budget [Integer] maximum tokens to include (positive)
  # @return [Array<Hash>] Anthropic Messages API format
  def messages_for_llm(token_budget: DEFAULT_TOKEN_BUDGET)
    assemble_messages(viewport_events(token_budget: token_budget))
  end

  private

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
