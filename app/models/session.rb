# frozen_string_literal: true

class Session < ApplicationRecord
  has_many :events, -> { order(:id) }, dependent: :destroy

  # Returns conversation messages suitable for LLM API calls.
  # Excludes system/tool events — only user and agent messages are included.
  def messages_for_llm
    events.llm_messages.map do |event|
      role = (event.event_type == "user_message") ? "user" : "assistant"
      {role: role, content: event.payload["content"].to_s}
    end
  end
end
