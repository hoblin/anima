# frozen_string_literal: true

class Event < ApplicationRecord
  TYPES = %w[system_message user_message agent_message tool_call tool_response].freeze
  LLM_TYPES = %w[user_message agent_message].freeze

  belongs_to :session

  validates :event_type, presence: true, inclusion: {in: TYPES}
  validates :payload, presence: true
  validates :position, presence: true, numericality: {only_integer: true, greater_than_or_equal_to: 0}
  validates :timestamp, presence: true

  scope :llm_messages, -> { where(event_type: LLM_TYPES) }

  before_validation :assign_position, on: :create

  private

  def assign_position
    return if position.present?

    max = self.class.where(session_id: session_id).maximum(:position)
    self.position = max ? max + 1 : 0
  end
end
