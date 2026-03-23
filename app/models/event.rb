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
#   @return [String] Anthropic-assigned ID correlating tool_call and tool_response
#     (required for tool_call and tool_response events)
class Event < ApplicationRecord
  include Event::Broadcasting

  TYPES = %w[system_message user_message agent_message tool_call tool_response].freeze
  LLM_TYPES = %w[user_message agent_message].freeze
  CONTEXT_TYPES = %w[system_message user_message agent_message tool_call tool_response].freeze
  CONVERSATION_TYPES = %w[user_message agent_message system_message].freeze
  THINK_TOOL = "think"
  SPAWN_TOOLS = %w[spawn_subagent spawn_specialist].freeze
  PENDING_STATUS = "pending"

  TOOL_TYPES = %w[tool_call tool_response].freeze

  ROLE_MAP = {"user_message" => "user", "agent_message" => "assistant"}.freeze

  # Heuristic: average bytes per token for English prose.
  BYTES_PER_TOKEN = 4

  belongs_to :session
  has_many :pinned_events, dependent: :destroy

  validates :event_type, presence: true, inclusion: {in: TYPES}
  validates :payload, presence: true
  validates :timestamp, presence: true
  validates :tool_use_id, presence: true, if: -> { event_type.in?(TOOL_TYPES) }

  after_create :schedule_token_count, if: :llm_message?

  # @!method self.llm_messages
  #   Events that represent conversation turns sent to the LLM API.
  #   @return [ActiveRecord::Relation]
  scope :llm_messages, -> { where(event_type: LLM_TYPES) }

  # @!method self.context_events
  #   Events included in the LLM context window (messages + tool interactions).
  #   @return [ActiveRecord::Relation]
  scope :context_events, -> { where(event_type: CONTEXT_TYPES) }

  # @!method self.pending
  #   User messages queued during active agent processing, not yet sent to LLM.
  #   @return [ActiveRecord::Relation]
  scope :pending, -> { where(status: PENDING_STATUS) }

  # @!method self.deliverable
  #   Events eligible for LLM context (excludes pending messages).
  #   NULL status means delivered/processed — the only excluded value is "pending".
  #   @return [ActiveRecord::Relation]
  scope :deliverable, -> { where(status: nil) }

  # @!method self.excluding_spawn_events
  #   Excludes spawn_subagent/spawn_specialist tool_call and tool_response events.
  #   Used when building parent context for sub-agents — spawn events cause role
  #   confusion because the sub-agent sees sibling spawn results and mistakes
  #   itself for the parent.
  #   @return [ActiveRecord::Relation]
  scope :excluding_spawn_events, -> {
    where.not("event_type IN (?) AND json_extract(payload, '$.tool_name') IN (?)",
      %w[tool_call tool_response], SPAWN_TOOLS)
  }

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

  # @return [Boolean] true if this is a pending message not yet sent to the LLM
  def pending?
    status == PENDING_STATUS
  end

  # @return [Boolean] true if this is a conversation event (user/agent/system message)
  #   or a think tool_call — the events Mneme treats as "conversation" for boundary tracking
  def conversation_or_think?
    event_type.in?(CONVERSATION_TYPES) ||
      (event_type == "tool_call" && payload["tool_name"] == THINK_TOOL)
  end

  # Heuristic token estimate: ~4 bytes per token for English prose.
  # Tool events are estimated from the full payload JSON since tool_input
  # and tool metadata contribute to token count. Messages use content only.
  #
  # @return [Integer] estimated token count (at least 1)
  def estimate_tokens
    text = if event_type.in?(TOOL_TYPES)
      payload.to_json
    else
      payload["content"].to_s
    end
    [(text.bytesize / BYTES_PER_TOKEN.to_f).ceil, 1].max
  end

  private

  def schedule_token_count
    CountEventTokensJob.perform_later(id)
  end
end
