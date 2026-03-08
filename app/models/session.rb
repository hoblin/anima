# frozen_string_literal: true

# A conversation session — the fundamental unit of agent interaction.
# Owns an ordered stream of {Event} records representing everything
# that happened: user messages, agent responses, tool calls, etc.
class Session < ApplicationRecord
  # Claude Sonnet 4 context window minus system prompt reserve.
  DEFAULT_TOKEN_BUDGET = 190_000

  # Heuristic: average bytes per token for English prose.
  BYTES_PER_TOKEN = 4

  has_many :events, -> { order(:id) }, dependent: :destroy

  # Builds the message array expected by the Anthropic Messages API.
  # Walks events newest-first and includes them until the token budget
  # is exhausted. Events are full-size or excluded entirely.
  #
  # Events whose token_count is still 0 (not yet counted by the
  # background job) use a {BYTES_PER_TOKEN}-bytes-per-token heuristic
  # to avoid dropping uncounted messages.
  #
  # @param token_budget [Integer] maximum tokens to include (positive)
  # @return [Array<Hash{Symbol => String}>] e.g. [{role: "user", content: "hi"}]
  def messages_for_llm(token_budget: DEFAULT_TOKEN_BUDGET)
    selected = []
    remaining = token_budget

    events.llm_messages.reorder(id: :desc).each do |event|
      cost = (event.token_count > 0) ? event.token_count : estimate_tokens(event)
      break if cost > remaining && selected.any?

      selected << event
      remaining -= cost
    end

    selected.reverse.map do |event|
      {role: event.api_role, content: event.payload["content"].to_s}
    end
  end

  private

  # Rough estimate for events not yet counted by the background job.
  # Uses the {BYTES_PER_TOKEN}-bytes-per-token heuristic.
  #
  # @param event [Event]
  # @return [Integer] at least 1
  def estimate_tokens(event)
    content = event.payload["content"].to_s
    [(content.bytesize / BYTES_PER_TOKEN.to_f).ceil, 1].max
  end
end
