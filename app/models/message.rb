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
#   @return [Integer] token count for this message's payload. Seeded with
#     a local estimate on create and later refined by {CountMessageTokensJob}
#     using the real Anthropic tokenizer. Always positive — never zero or nil.
# @!attribute tool_use_id
#   @return [String] ID correlating tool_call and tool_response messages
#     (Anthropic-assigned, or a SecureRandom.uuid fallback when the API returns nil;
#     required for tool_call and tool_response messages)
class Message < ApplicationRecord
  include Message::Broadcasting

  TYPES = %w[system_message user_message agent_message tool_call tool_response].freeze
  LLM_TYPES = %w[user_message agent_message].freeze
  CONVERSATION_TYPES = %w[user_message agent_message system_message].freeze
  THINK_TOOL = "think"
  # Message types that require a tool_use_id to pair call with response.
  TOOL_TYPES = %w[tool_call tool_response].freeze

  ROLE_MAP = {"user_message" => "user", "agent_message" => "assistant"}.freeze

  # Heuristic: average bytes per token for English prose.
  BYTES_PER_TOKEN = 4

  # Synthetic ID for system prompt entries in the TUI message store.
  # Real message IDs are positive integers from the database, so 0
  # is safe for deduplication without collision risk.
  SYSTEM_PROMPT_ID = 0

  # Estimates token count from a byte size using the {BYTES_PER_TOKEN} heuristic.
  # @param bytesize [Integer] number of bytes
  # @return [Integer] estimated token count (at least 1)
  def self.estimate_token_count(bytesize)
    [(bytesize / BYTES_PER_TOKEN.to_f).ceil, 1].max
  end

  belongs_to :session
  has_many :pinned_messages, dependent: :destroy

  validates :message_type, presence: true, inclusion: {in: TYPES}
  validates :payload, presence: true
  validates :timestamp, presence: true
  # Anthropic requires every tool_use to have a matching tool_result with the same ID
  validates :tool_use_id, presence: true, if: -> { message_type.in?(TOOL_TYPES) }

  before_validation :set_estimated_token_count, on: :create
  after_create :schedule_token_count

  # @!method self.llm_messages
  #   Messages that represent conversation turns sent to the LLM API.
  #   @return [ActiveRecord::Relation]
  scope :llm_messages, -> { where(message_type: LLM_TYPES) }

  # Maps message_type to the Anthropic Messages API role.
  # @return [String] "user" or "assistant"
  def api_role
    ROLE_MAP.fetch(message_type)
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
    self.class.estimate_token_count(text.bytesize)
  end

  private

  # Seeds {#token_count} with a local estimate before the record is saved.
  # The background {CountMessageTokensJob} later refines this value with the
  # real Anthropic tokenizer count. Respects an explicit positive value
  # passed by the caller (e.g. tests that want deterministic counts) and
  # bails out for records that don't yet have a payload — they'll fail
  # presence validation right after this callback.
  def set_estimated_token_count
    return if token_count.to_i.positive?
    return if payload.blank?

    self.token_count = estimate_tokens
  end

  def schedule_token_count
    CountMessageTokensJob.perform_later(id)
  end
end
