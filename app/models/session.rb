# frozen_string_literal: true

# A conversation session — the fundamental unit of agent interaction.
# Owns an ordered stream of {Event} records representing everything
# that happened: user messages, agent responses, tool calls, etc.
class Session < ApplicationRecord
  # Claude Sonnet 4 context window minus system prompt reserve.
  DEFAULT_TOKEN_BUDGET = 190_000

  has_many :events, -> { order(:id) }, dependent: :destroy

  # Builds the message array expected by the Anthropic Messages API.
  # Walks events newest-first and includes them until the token budget
  # is exhausted. Events are full-size or excluded entirely.
  #
  # Events whose token_count is still 0 (not yet counted) are included
  # and their tokens estimated at 1 per event to avoid dropping uncounted messages.
  #
  # @param token_budget [Integer] maximum tokens to include
  # @return [Array<Hash{Symbol => String}>] e.g. [{role: "user", content: "hi"}]
  def messages_for_llm(token_budget: DEFAULT_TOKEN_BUDGET)
    selected = []
    remaining = token_budget

    events.llm_messages.reorder(id: :desc).each do |event|
      cost = (event.token_count > 0) ? event.token_count : estimate_tokens(event)
      break if cost > remaining && selected.any?

      selected.unshift(event)
      remaining -= cost
    end

    selected.map do |event|
      role = (event.event_type == "user_message") ? "user" : "assistant"
      {role: role, content: event.payload["content"].to_s}
    end
  end

  private

  # Rough estimate for events not yet counted by the background job.
  # Uses the 4-characters-per-token heuristic.
  #
  # @param event [Event]
  # @return [Integer]
  def estimate_tokens(event)
    content = event.payload["content"].to_s
    (content.bytesize / 4.0).ceil.clamp(1, Float::INFINITY).to_i
  end
end
