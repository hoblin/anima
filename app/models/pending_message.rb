# frozen_string_literal: true

# A message waiting to enter a session's conversation history.
# Pending messages live in their own table — they are NOT part of the
# message stream and have no database ID that could interleave with
# tool_call/tool_response pairs.
#
# Entry point of the event-driven drain pipeline. Every inbound
# message destined for the LLM — user input, tool responses,
# sub-agent replies, Mneme recalls, Melete skills/goals — lands here
# first, then gets promoted into a real {Message} by {DrainJob}.
#
# Each pending message knows its source (+source_type+, +source_name+)
# and how to serialize itself for the LLM conversation via {#to_llm_messages}.
# Non-user messages (sub-agent results, recalled skills, workflows, recall,
# goal events) become synthetic tool_use/tool_result pairs so the LLM sees
# "a tool I invoked returned a result" rather than "a user wrote me."
#
# Classifies itself for the pipeline via +kind+ (+active+ triggers the
# drain loop, +background+ enriches context silently) and +message_type+
# (selects which pipeline event to emit on create).
#
# @see Session#enqueue_user_message
# @see DrainJob — promotes PMs into Messages
# @see Events::StartMneme
# @see Events::StartProcessing
class PendingMessage < ApplicationRecord
  # Phantom tool names follow the `from_<sender>` convention: the prefix
  # tells the LLM these are messages delivered to it by its sisters or
  # sub-agents, not tools it invoked. Melete's contributions carry the
  # type in the suffix so the viewport query can filter by kind.
  MELETE_SKILL_TOOL = "from_melete_skill"
  MELETE_WORKFLOW_TOOL = "from_melete_workflow"
  MELETE_GOAL_TOOL = "from_melete_goal"
  MNEME_TOOL = "from_mneme"

  # Source types that produce phantom tool_use/tool_result pairs on promotion.
  # User messages produce plain text blocks instead.
  PHANTOM_PAIR_TYPES = %w[subagent skill workflow recall goal].freeze

  # Maps each phantom pair source type to a lambda that builds its
  # synthetic tool name. Each Melete contribution carries the type in
  # its suffix; recalled memories come from Mneme; sub-agents encode
  # their nickname directly (e.g. `from_sleuth`).
  PHANTOM_TOOL_NAMES = {
    "subagent" => ->(name) { "from_#{name}" },
    "skill" => ->(_) { MELETE_SKILL_TOOL },
    "workflow" => ->(_) { MELETE_WORKFLOW_TOOL },
    "recall" => ->(_) { MNEME_TOOL },
    "goal" => ->(_) { MELETE_GOAL_TOOL }
  }.freeze

  # Maps each phantom pair source type to a lambda building its tool input.
  PHANTOM_TOOL_INPUTS = {
    "subagent" => ->(name) { {from: name} },
    "skill" => ->(name) { {skill: name} },
    "workflow" => ->(name) { {workflow: name} },
    "recall" => ->(name) { {message_id: name.to_i} },
    "goal" => ->(name) { {goal_id: name.to_i} }
  }.freeze

  # Every message_type has a defined drain-pipeline role. +active+ types
  # trigger the drain loop when the session is idle; +background+ types
  # enrich context silently and ride the next active turn into the LLM.
  # {#kind} is derived from this map in {#derive_kind} — callers only
  # supply +message_type+.
  MESSAGE_TYPE_KINDS = {
    "user_message" => "active",
    "tool_response" => "active",
    "subagent" => "active",
    "from_mneme" => "background",
    "from_melete_skill" => "background",
    "from_melete_workflow" => "background",
    "from_melete_goal" => "background"
  }.freeze

  MESSAGE_TYPES = MESSAGE_TYPE_KINDS.keys.freeze

  # Routes active message types to the event that begins the drain pipeline.
  # User messages enrich context first (Mneme → Melete → Processing);
  # tool responses and sub-agent deliveries bypass enrichment and go
  # straight to the drain loop. Background message types route to nothing
  # — they wait in the mailbox until an active turn drains them.
  MESSAGE_TYPE_ROUTES = {
    "user_message" => Events::StartMneme,
    "tool_response" => Events::StartProcessing,
    "subagent" => Events::StartProcessing
  }.freeze

  belongs_to :session

  # In-memory id of the +Message+ this PM becomes on {#promote!}. Not
  # persisted — the PM row is destroyed as part of the promotion transaction.
  # Used by {Session#release_with_bounce_back} to destroy the exact message
  # that should bounce, instead of guessing from +messages.last+ (which could
  # race under parallel drains).
  attr_accessor :promoted_message_id

  enum :kind, {background: "background", active: "active"}

  before_validation :derive_kind, if: :message_type

  validates :content, presence: true
  validates :source_name, presence: true, unless: :user?
  validates :message_type, presence: true, inclusion: {in: MESSAGE_TYPES}
  validates :tool_use_id, presence: true, if: -> { message_type == "tool_response" }

  # Tool responses take priority over other active messages: they complete
  # a tool round the LLM is waiting on, so promoting them first preserves
  # the tool_use/tool_result pairing in the conversation. Other actives
  # (user messages, sub-agent replies) wait their FIFO turn behind the
  # completion.
  scope :ordered_for_drain, -> {
    active.order(Arel.sql("message_type = 'tool_response' DESC")).order(:created_at)
  }

  after_create_commit :broadcast_created
  after_create_commit :route_to_event_bus
  after_destroy_commit :broadcast_removed

  # @return [Boolean] true when this is a plain user message
  def user?
    source_type == "user"
  end

  # @return [Boolean] true when this message originated from a sub-agent
  def subagent?
    source_type == "subagent"
  end

  # @return [Boolean] true when this message carries recalled skill content
  def skill?
    source_type == "skill"
  end

  # @return [Boolean] true when this message carries recalled workflow content
  def workflow?
    source_type == "workflow"
  end

  # @return [Boolean] true when this message is an associative recall phantom pair
  def recall?
    source_type == "recall"
  end

  # @return [Boolean] true when this message carries a goal event
  def goal?
    source_type == "goal"
  end

  # @return [Boolean] true when promotion produces phantom tool_use/tool_result pairs
  def phantom_pair?
    source_type.in?(PHANTOM_PAIR_TYPES)
  end

  # Promotes this PendingMessage into the session's conversation history.
  # Dispatches on +message_type+: tool responses become +tool_response+
  # Messages, user messages become +user_message+ Messages, phantom pair
  # types (sub-agent, skill, workflow, recall, goal) become synthetic
  # tool_use/tool_result pairs. The PM row is destroyed in the same
  # transaction so partial promotion can never leave a stray mailbox entry.
  #
  # For promotions that yield a single Message, {#promoted_message_id}
  # captures the new record's id — callers can then act on that specific
  # message (e.g. {Session#release_with_bounce_back}) without guessing.
  #
  # @return [void]
  def promote!
    session.transaction do
      if message_type == "tool_response"
        self.promoted_message_id = promote_as_tool_response!.id
      elsif message_type == "user_message"
        self.promoted_message_id = session.create_user_message(
          display_content,
          source_type: source_type,
          source_name: source_name
        ).id
      elsif phantom_pair?
        promote_as_phantom_pair!
      else
        raise "PendingMessage ##{id} cannot promote: message_type=#{message_type.inspect}"
      end
      destroy!
    end
  end

  # Phantom tool name for DB persistence and LLM injection.
  # Each phantom pair source type maps to a synthetic tool name via
  # {PHANTOM_TOOL_NAMES} — a lambda so sub-agent names can flow through.
  #
  # @return [String] phantom tool name
  def phantom_tool_name
    PHANTOM_TOOL_NAMES.fetch(source_type).call(source_name)
  end

  # Phantom tool input hash for DB persistence and LLM injection.
  #
  # @return [Hash] tool input hash
  def phantom_tool_input
    PHANTOM_TOOL_INPUTS.fetch(source_type).call(source_name)
  end

  # Content formatted for display and history persistence.
  # Sub-agent messages include an attribution prefix. Skill/workflow
  # messages include a recall label. User messages pass through unchanged.
  #
  # @return [String]
  def display_content
    case source_type
    when "subagent"
      format(Tools::ResponseTruncator::ATTRIBUTION_FORMAT, source_name, content)
    when "skill"
      "[recalled skill: #{source_name}]\n#{content}"
    when "workflow"
      "[recalled workflow: #{source_name}]\n#{content}"
    when "goal"
      "[goal #{source_name}]\n#{content}"
    else
      content
    end
  end

  # Builds LLM message hashes for this pending message.
  #
  # Phantom pair types become synthetic tool_use/tool_result pairs so the
  # LLM sees them as its own past invocations. User messages return plain
  # content for injection as text blocks within the current tool_results turn.
  #
  # @return [Array<Hash>] synthetic tool pair for phantom pair types
  # @return [String] raw content for user messages
  def to_llm_messages
    return content unless phantom_pair?

    build_phantom_pair(phantom_tool_name, phantom_tool_input)
  end

  # Emits the event that kicks off the drain pipeline for active messages
  # whenever the session is currently claimable. Claimability is delegated
  # to the AASM via +may_start_processing?+ — true from +:idle+ always,
  # true from +:executing+ only once +tool_round_complete?+ holds. This
  # lets a tool_response PM landing mid-round wake the drain only when
  # its sibling responses are all present.
  #
  # Background messages never trigger; active messages landing while the
  # session is unclaimable queue silently —
  # {Session#wake_drain_pipeline_if_pending} re-invokes this on the next
  # transition into +:idle+.
  #
  # Also fires from +after_create_commit+ so freshly enqueued PMs route
  # themselves on persistence.
  def route_to_event_bus
    return unless active?
    return unless session.may_start_processing?

    event_class = MESSAGE_TYPE_ROUTES.fetch(message_type)
    Events::Bus.emit(event_class.new(session_id: session_id, pending_message_id: id))
  end

  private

  # Persists a +tool_response+ Message for this PM and returns it.
  # Mirrors the tool_use_id / payload shape emitted by
  # {Events::Subscribers::LLMResponseHandler} for the paired +tool_call+.
  #
  # @return [Message]
  def promote_as_tool_response!
    session.messages.create!(
      message_type: "tool_response",
      tool_use_id: tool_use_id,
      payload: {
        "tool_name" => source_name,
        "tool_use_id" => tool_use_id,
        "content" => content,
        "success" => success
      },
      timestamp: Time.current.to_ns,
      token_count: TokenEstimation.estimate_token_count(content)
    )
  end

  # Persists a synthetic +tool_call+/+tool_response+ Message pair so the
  # LLM sees this contribution (sub-agent delivery, Melete skill/workflow/
  # goal, Mneme recall) as a past tool invocation of its own. Keeps the
  # system prompt stable for prompt caching — phantom pairs flow through
  # the sliding-window conversation instead.
  #
  # @return [void]
  def promote_as_phantom_pair!
    tool_name = phantom_tool_name
    uid = "#{tool_name}_#{id}"
    now = Time.current.to_ns

    session.messages.create!(
      message_type: "tool_call",
      tool_use_id: uid,
      payload: {
        "tool_name" => tool_name,
        "tool_use_id" => uid,
        "tool_input" => phantom_tool_input.stringify_keys,
        "content" => display_content.lines.first.chomp
      },
      timestamp: now,
      token_count: Mneme::TOOL_PAIR_OVERHEAD_TOKENS
    )

    session.messages.create!(
      message_type: "tool_response",
      tool_use_id: uid,
      payload: {
        "tool_name" => tool_name,
        "tool_use_id" => uid,
        "content" => content,
        "success" => true
      },
      timestamp: now,
      token_count: TokenEstimation.estimate_token_count(content)
    )
  end

  # Builds a phantom tool_use/tool_result message pair.
  # Follows the same format for all non-user source types — the only
  # difference is the tool name and input hash.
  #
  # Phantom pairs keep the system prompt stable for prompt caching (#395).
  # Instead of injecting skills/workflows into the system prompt (which
  # busts the cache on every change), they flow through the sliding window
  # as messages the LLM "recalls" via phantom tool invocations.
  #
  # @param tool_name [String] phantom tool name (not in the agent's registry)
  # @param input [Hash] tool input hash
  # @return [Array<Hash>] two-element array: assistant tool_use + user tool_result
  def build_phantom_pair(tool_name, input)
    tool_use_id = "#{tool_name}_#{id}"
    [
      {role: "assistant", content: [
        {type: "tool_use", id: tool_use_id, name: tool_name, input: input}
      ]},
      {role: "user", content: [
        {type: "tool_result", tool_use_id: tool_use_id, content: content}
      ]}
    ]
  end

  # Broadcasts a pending message appearance so TUI clients render the
  # dimmed indicator immediately.
  def broadcast_created
    ActionCable.server.broadcast("session_#{session_id}", {
      "action" => "pending_message_created",
      "pending_message_id" => id,
      "content" => content
    })
  end

  # Broadcasts pending message removal so TUI clients clear the entry.
  # Fires on both promotion (normal flow) and recall (user edit).
  def broadcast_removed
    ActionCable.server.broadcast("session_#{session_id}", {
      "action" => "pending_message_removed",
      "pending_message_id" => id
    })
  end

  # Populates +kind+ from {MESSAGE_TYPE_KINDS} so callers only need to
  # supply +message_type+. The mapping is the single source of truth for
  # whether a message type triggers the drain loop or rides along as
  # enrichment. Guarded by +if: :message_type+ on the callback — rows
  # without a +message_type+ fail validation explicitly rather than
  # crashing here.
  def derive_kind
    self.kind = MESSAGE_TYPE_KINDS.fetch(message_type)
  end
end
