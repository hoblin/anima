# frozen_string_literal: true

# A user message waiting to enter a session's conversation history.
# Pending messages live in their own table — they are NOT part of the
# message stream and have no database ID that could interleave with
# tool_call/tool_response pairs.
#
# Created when a user sends a message while the session is processing.
# Promoted to a real {Message} (delete + create in transaction) when
# the current agent loop completes, giving the new message an ID that
# naturally follows the tool batch.
#
# @see Session#enqueue_user_message
# @see Session#promote_pending_messages!
class PendingMessage < ApplicationRecord
  belongs_to :session

  validates :content, presence: true

  after_create_commit :broadcast_created
  after_destroy_commit :broadcast_removed

  private

  # Broadcasts a pending message appearance so TUI clients render the
  # clock-icon indicator immediately.
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
