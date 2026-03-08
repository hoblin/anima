# frozen_string_literal: true

class Session < ApplicationRecord
  has_many :events, -> { order(:position) }, dependent: :destroy

  # Builds the LLM-compatible messages array from persisted events.
  # Only user_message and agent_message are included — matches MessageCollector's filtering.
  def messages_for_llm
    events.where(event_type: %w[user_message agent_message]).map do |event|
      role = (event.event_type == "user_message") ? "user" : "assistant"
      {role: role, content: event.payload["content"]}
    end
  end
end
