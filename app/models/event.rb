# frozen_string_literal: true

class Event < ApplicationRecord
  TYPES = %w[system_message user_message agent_message tool_call tool_response].freeze
  LLM_TYPES = %w[user_message agent_message].freeze

  belongs_to :session

  validates :event_type, presence: true, inclusion: {in: TYPES}
  validates :payload, presence: true
  validates :timestamp, presence: true

  scope :llm_messages, -> { where(event_type: LLM_TYPES) }
end
