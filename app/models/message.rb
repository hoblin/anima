# frozen_string_literal: true

# A persisted record of what was said during a session — by whom and when.
# Messages are the single source of truth for conversation history —
# there is no separate chat log, only messages attached to a session.
#
# Not to be confused with {Events::Base} (transient bus signals).
# Messages persist to SQLite; events flow through the bus and are gone.
#
# After commit, emits {Events::MessageCreated} and {Events::MessageUpdated}
# lifecycle events so subscribers ({Events::Subscribers::MessageBroadcaster},
# {Events::Subscribers::MnemeScheduler}) can react without coupling.
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
#     a local estimate on create and later refined by {CountTokensJob} using
#     the real Anthropic tokenizer. Always positive — never zero or nil.
# @!attribute tool_use_id
#   @return [String] ID correlating tool_call and tool_response messages
#     (Anthropic-assigned, or a SecureRandom.uuid fallback when the API returns nil;
#     required for tool_call and tool_response messages)
class Message < ApplicationRecord
  include TokenEstimation

  TYPES = %w[system_message user_message agent_message tool_call tool_response].freeze
  LLM_TYPES = %w[user_message agent_message].freeze
  CONVERSATION_TYPES = %w[user_message agent_message system_message].freeze
  THINK_TOOL = "think"
  # Message types that require a tool_use_id to pair call with response.
  TOOL_TYPES = %w[tool_call tool_response].freeze

  ROLE_MAP = {"user_message" => "user", "agent_message" => "assistant"}.freeze

  # Synthetic ID for system prompt entries in the TUI message store.
  # Real message IDs are positive integers from the database, so 0
  # is safe for deduplication without collision risk.
  SYSTEM_PROMPT_ID = 0

  belongs_to :session
  has_many :pinned_messages, dependent: :destroy

  validates :message_type, presence: true, inclusion: {in: TYPES}
  validates :payload, presence: true
  validates :timestamp, presence: true
  # Anthropic requires every tool_use to have a matching tool_result with the same ID
  validates :tool_use_id, presence: true, if: -> { message_type.in?(TOOL_TYPES) }

  after_create_commit :emit_created_event
  after_update_commit :emit_updated_event

  # @!method self.llm_messages
  #   Messages that represent conversation turns sent to the LLM API.
  #   @return [ActiveRecord::Relation]
  scope :llm_messages, -> { where(message_type: LLM_TYPES) }

  # @!method self.conversation_or_think
  #   Conversation messages (user/agent/system) and think tool_calls —
  #   the messages Mneme treats as boundary-eligible.
  #   @return [ActiveRecord::Relation]
  scope :conversation_or_think, -> {
    where(message_type: CONVERSATION_TYPES)
      .or(where(message_type: "tool_call")
        .where("json_extract(payload, '$.tool_name') = ?", THINK_TOOL))
  }

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

  # String fed to the token estimator and the remote tokenizer. Tool
  # messages serialize the full payload as JSON so +tool_name+, +tool_input+,
  # and +tool_use_id+ contribute to the count; conversation messages use
  # the content field only.
  #
  # @return [String]
  def tokenization_text
    if message_type.in?(TOOL_TYPES)
      payload.to_json
    else
      payload["content"].to_s
    end
  end

  private

  def emit_created_event
    Events::Bus.emit(Events::MessageCreated.new(self))
  end

  def emit_updated_event
    Events::Bus.emit(Events::MessageUpdated.new(self))
  end
end
