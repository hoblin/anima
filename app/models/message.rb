# frozen_string_literal: true

# A persisted record of what was said during a session — by whom and when.
# Messages are the single source of truth for conversation history —
# there is no separate chat log, only messages attached to a session.
#
# Not to be confused with {Events::Base} (transient bus signals).
# Messages persist to SQLite; events flow through the bus and are gone.
#
# @!attribute message_type
#   @return [String] one of {TYPES}: system_message, user_message,
#     agent_message, tool_call, tool_response
# @!attribute payload
#   @return [Hash] message-specific data (content, tool_name, tool_input, etc.)
# @!attribute timestamp
#   @return [Integer] nanoseconds since epoch (Process::CLOCK_REALTIME)
# @!attribute token_count
#   @return [Integer] cached token count for this message's payload (0 until counted)
# @!attribute tool_use_id
#   @return [String] ID correlating tool_call and tool_response messages
#     (Anthropic-assigned, or a SecureRandom.uuid fallback when the API returns nil;
#     required for tool_call and tool_response messages)
class Message < ApplicationRecord
  include Message::Broadcasting

  TYPES = %w[system_message user_message agent_message tool_call tool_response].freeze
  LLM_TYPES = %w[user_message agent_message].freeze
  CONTEXT_TYPES = %w[system_message user_message agent_message tool_call tool_response].freeze
  CONVERSATION_TYPES = %w[user_message agent_message system_message].freeze
  THINK_TOOL = "think"
  SPAWN_TOOLS = %w[spawn_subagent spawn_specialist].freeze
  PENDING_STATUS = "pending"

  # Message types that require a tool_use_id to pair call with response.
  TOOL_TYPES = %w[tool_call tool_response].freeze

  ROLE_MAP = {"user_message" => "user", "agent_message" => "assistant"}.freeze

  # Heuristic: average bytes per token for English prose.
  BYTES_PER_TOKEN = 4

  belongs_to :session
  has_many :pinned_messages, dependent: :destroy

  validates :message_type, presence: true, inclusion: {in: TYPES}
  validates :payload, presence: true
  validates :timestamp, presence: true
  # Anthropic requires every tool_use to have a matching tool_result with the same ID
  validates :tool_use_id, presence: true, if: -> { message_type.in?(TOOL_TYPES) }

  after_create :schedule_token_count, if: :llm_message?

  # @!method self.llm_messages
  #   Messages that represent conversation turns sent to the LLM API.
  #   @return [ActiveRecord::Relation]
  scope :llm_messages, -> { where(message_type: LLM_TYPES) }

  # @!method self.context_messages
  #   Messages included in the LLM context window (conversation + tool interactions).
  #   @return [ActiveRecord::Relation]
  scope :context_messages, -> { where(message_type: CONTEXT_TYPES) }

  # @!method self.pending
  #   User messages queued during active agent processing, not yet sent to LLM.
  #   @return [ActiveRecord::Relation]
  scope :pending, -> { where(status: PENDING_STATUS) }

  # @!method self.deliverable
  #   Messages eligible for LLM context (excludes pending messages).
  #   NULL status means delivered/processed — the only excluded value is "pending".
  #   @return [ActiveRecord::Relation]
  scope :deliverable, -> { where(status: nil) }

  # @!method self.excluding_spawn_messages
  #   Excludes spawn_subagent/spawn_specialist tool_call and tool_response messages.
  #   Used when building parent context for sub-agents — spawn messages cause role
  #   confusion because the sub-agent sees sibling spawn results and mistakes
  #   itself for the parent.
  #   @return [ActiveRecord::Relation]
  scope :excluding_spawn_messages, -> {
    where.not("message_type IN (?) AND json_extract(payload, '$.tool_name') IN (?)",
      TOOL_TYPES, SPAWN_TOOLS)
  }

  # Maps message_type to the Anthropic Messages API role.
  # @return [String] "user" or "assistant"
  def api_role
    ROLE_MAP.fetch(message_type)
  end

  # @return [Boolean] true if this message represents an LLM conversation turn
  def llm_message?
    message_type.in?(LLM_TYPES)
  end

  # @return [Boolean] true if this message is part of the LLM context window
  def context_message?
    message_type.in?(CONTEXT_TYPES)
  end

  # @return [Boolean] true if this is a pending message not yet sent to the LLM
  def pending?
    status == PENDING_STATUS
  end

  # @return [Boolean] true if this is a conversation message (user/agent/system)
  #   or a think tool_call — the messages Mneme treats as "conversation" for boundary tracking
  def conversation_or_think?
    message_type.in?(CONVERSATION_TYPES) ||
      (message_type == "tool_call" && payload["tool_name"] == THINK_TOOL)
  end

  # Heuristic token estimate: ~4 bytes per token for English prose.
  # Tool messages are estimated from the full payload JSON since tool_input
  # and tool metadata contribute to token count. Messages use content only.
  #
  # @return [Integer] estimated token count (at least 1)
  def estimate_tokens
    text = if message_type.in?(TOOL_TYPES)
      payload.to_json
    else
      payload["content"].to_s
    end
    [(text.bytesize / BYTES_PER_TOKEN.to_f).ceil, 1].max
  end

  private

  def schedule_token_count
    CountMessageTokensJob.perform_later(id)
  end
end
