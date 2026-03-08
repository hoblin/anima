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
# @!attribute tool_use_id
#   @return [String, nil] Anthropic-assigned ID correlating tool_call and tool_response
class Event < ApplicationRecord
  TYPES = %w[system_message user_message agent_message tool_call tool_response].freeze
  LLM_TYPES = %w[user_message agent_message].freeze
  CONTEXT_TYPES = %w[user_message agent_message tool_call tool_response].freeze

  ROLE_MAP = {"user_message" => "user", "agent_message" => "assistant"}.freeze

  belongs_to :session

  validates :event_type, presence: true, inclusion: {in: TYPES}
  validates :payload, presence: true
  validates :timestamp, presence: true

  after_create :schedule_token_count, if: :llm_message?

  # @!method self.llm_messages
  #   Events that represent conversation turns sent to the LLM API.
  #   @return [ActiveRecord::Relation]
  scope :llm_messages, -> { where(event_type: LLM_TYPES) }

  # @!method self.context_events
  #   Events included in the LLM context window (messages + tool interactions).
  #   @return [ActiveRecord::Relation]
  scope :context_events, -> { where(event_type: CONTEXT_TYPES) }

  # Maps event_type to the Anthropic Messages API role.
  # @return [String] "user" or "assistant"
  def api_role
    ROLE_MAP.fetch(event_type)
  end

  # @return [Boolean] true if this event represents an LLM conversation turn
  def llm_message?
    event_type.in?(LLM_TYPES)
  end

  # @return [Boolean] true if this event is part of the LLM context window
  def context_event?
    event_type.in?(CONTEXT_TYPES)
  end

  private

  def schedule_token_count
    CountEventTokensJob.perform_later(id)
  end
end
