# frozen_string_literal: true

# A persisted record of something that happened during a session.
# Events are the single source of truth for conversation history —
# there is no separate chat log, only events attached to a session.
#
# @!attribute event_type
#   @return [String] one of {TYPES}: system_message, user_message,
#     agent_message, tool_call, tool_response
# @!attribute payload
#   @return [Hash] event-specific data (content, tool_name, tool_input, etc.)
# @!attribute timestamp
#   @return [Integer] nanoseconds since epoch (Process::CLOCK_REALTIME)
# @!attribute token_count
#   @return [Integer] cached token count for this event's payload (0 until counted)
class Event < ApplicationRecord
  TYPES = %w[system_message user_message agent_message tool_call tool_response].freeze
  LLM_TYPES = %w[user_message agent_message].freeze

  belongs_to :session

  validates :event_type, presence: true, inclusion: {in: TYPES}
  validates :payload, presence: true
  validates :timestamp, presence: true

  after_create :schedule_token_count

  # @!method self.llm_messages
  #   Events that represent conversation turns sent to the LLM API.
  #   @return [ActiveRecord::Relation]
  scope :llm_messages, -> { where(event_type: LLM_TYPES) }

  private

  def schedule_token_count
    CountEventTokensJob.perform_later(id)
  end
end
