# frozen_string_literal: true

# A message waiting to enter a session's conversation history.
# Pending messages live in their own table — they are NOT part of the
# message stream and have no database ID that could interleave with
# tool_call/tool_response pairs.
#
# Created when a message arrives while the session is processing.
# Promoted to a real {Message} (delete + create in transaction) when
# the current agent loop completes, giving the new message an ID that
# naturally follows the tool batch.
#
# Each pending message knows its source (+source_type+, +source_name+)
# and how to serialize itself for the LLM conversation via {#to_llm_messages}.
# Non-user messages (sub-agent results, recalled skills, workflows, recall,
# goal events) become synthetic tool_use/tool_result pairs so the LLM sees
# "a tool I invoked returned a result" rather than "a user wrote me."
#
# @see Session#enqueue_user_message
# @see Session#promote_pending_messages!
class PendingMessage < ApplicationRecord
  # Phantom tool names follow the `from_<sender>` convention: the prefix
  # tells the LLM these are messages delivered to it by its sisters or
  # sub-agents, not tools it invoked. Aoide's system prompt calls the
  # convention out in one line and the weights do the rest.
  MELETE_TOOL = "from_melete"
  MNEME_TOOL = "from_mneme"

  # Source types that produce phantom tool_use/tool_result pairs on promotion.
  # User messages produce plain text blocks instead.
  PHANTOM_PAIR_TYPES = %w[subagent skill workflow recall goal].freeze

  # Maps each phantom pair source type to a lambda that builds its
  # synthetic tool name. Skills, workflows, and goals all come from
  # Melete; recalled memories come from Mneme; sub-agents encode their
  # nickname directly into the tool name (e.g. `from_sleuth`).
  PHANTOM_TOOL_NAMES = {
    "subagent" => ->(name) { "from_#{name}" },
    "skill" => ->(_) { MELETE_TOOL },
    "workflow" => ->(_) { MELETE_TOOL },
    "recall" => ->(_) { MNEME_TOOL },
    "goal" => ->(_) { MELETE_TOOL }
  }.freeze

  # Maps each phantom pair source type to a lambda building its tool input.
  PHANTOM_TOOL_INPUTS = {
    "subagent" => ->(name) { {from: name} },
    "skill" => ->(name) { {skill: name} },
    "workflow" => ->(name) { {workflow: name} },
    "recall" => ->(name) { {message_id: name.to_i} },
    "goal" => ->(name) { {goal_id: name.to_i} }
  }.freeze

  belongs_to :session

  validates :content, presence: true
  validates :source_type, inclusion: {in: %w[user subagent skill workflow recall goal]}
  validates :source_name, presence: true, unless: :user?

  after_create_commit :broadcast_created
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

  private

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
end
