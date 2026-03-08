# frozen_string_literal: true

# A conversation session — the fundamental unit of agent interaction.
# Owns an ordered stream of {Event} records representing everything
# that happened: user messages, agent responses, tool calls, etc.
class Session < ApplicationRecord
  has_many :events, -> { order(:id) }, dependent: :destroy

  # Builds the message array expected by the Anthropic Messages API.
  # Only conversation turns (user/agent) are included — system messages,
  # tool calls, and tool responses are excluded.
  #
  # @return [Array<Hash{Symbol => String}>] e.g. [{role: "user", content: "hi"}]
  def messages_for_llm
    events.llm_messages.map do |event|
      role = (event.event_type == "user_message") ? "user" : "assistant"
      {role: role, content: event.payload["content"].to_s}
    end
  end
end
