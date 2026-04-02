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
# Sub-agent messages become synthetic tool_use/tool_result pairs so the LLM
# sees "a tool I invoked returned a result" rather than "a user wrote me."
#
# @see Session#enqueue_user_message
# @see Session#promote_pending_messages!
class PendingMessage < ApplicationRecord
  # Synthetic tool name used in tool_use/tool_result pairs injected into
  # the parent LLM conversation when a sub-agent message is promoted.
  SYNTHETIC_TOOL_NAME = "subagent_message"

  # Phantom tool name for associative recall — not in the agent's tool registry.
  RECALL_TOOL_NAME = "recall_memory"

  belongs_to :session

  validates :content, presence: true
  validates :source_type, inclusion: {in: %w[user subagent recall]}
  validates :source_name, presence: true, if: -> { subagent? || recall? }

  after_create_commit :broadcast_created
  after_destroy_commit :broadcast_removed

  # @return [Boolean] true when this message originated from a sub-agent
  def subagent?
    source_type == "subagent"
  end

  # @return [Boolean] true when this message is an associative recall phantom pair
  def recall?
    source_type == "recall"
  end

  # Content formatted for display and history persistence.
  # Sub-agent messages include an attribution prefix; user messages
  # pass through unchanged.
  #
  # @return [String]
  def display_content
    if subagent?
      format(Tools::ResponseTruncator::ATTRIBUTION_FORMAT, source_name, content)
    else
      content
    end
  end

  # Builds LLM message hashes for this pending message.
  #
  # Sub-agent and recall messages become synthetic tool_use/tool_result pairs
  # so the LLM associates them with tool invocation semantics.
  # User messages return plain content — they are injected as text blocks
  # within the current tool_results turn, not as separate conversation turns.
  #
  # @return [Array<Hash>] synthetic tool pair for sub-agent/recall messages
  # @return [String] raw content for user messages
  def to_llm_messages
    if subagent?
      tool_use_id = "subagent_msg_#{id}"
      [
        {role: "assistant", content: [
          {type: "tool_use", id: tool_use_id, name: SYNTHETIC_TOOL_NAME,
           input: {from: source_name}}
        ]},
        {role: "user", content: [
          {type: "tool_result", tool_use_id: tool_use_id, content: content}
        ]}
      ]
    elsif recall?
      tool_use_id = "recall_#{source_name}"
      [
        {role: "assistant", content: [
          {type: "tool_use", id: tool_use_id, name: RECALL_TOOL_NAME,
           input: {message_id: source_name.to_i}}
        ]},
        {role: "user", content: [
          {type: "tool_result", tool_use_id: tool_use_id, content: content}
        ]}
      ]
    else
      content
    end
  end

  private

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
