# frozen_string_literal: true

# Broadcasts Message records to connected WebSocket clients via ActionCable.
# Follows the Turbo Streams pattern: messages are broadcast on both create
# and update, with an action type so clients can distinguish append from
# replace operations.
#
# Each broadcast includes the Message's database ID, enabling clients to
# maintain an ID-indexed store for efficient in-place updates (e.g. when
# token counts arrive asynchronously from {CountMessageTokensJob}).
#
# When a new message pushes old messages out of the LLM's context window,
# the broadcast includes `evicted_message_ids` so clients can remove
# phantom messages that the agent no longer knows about.
#
# @example Create broadcast payload
#   {
#     "type" => "user_message", "content" => "hello", ...,
#     "id" => 42, "action" => "create",
#     "rendered" => { "basic" => { "role" => "user", "content" => "hello" } }
#   }
#
# @example Broadcast with viewport evictions
#   {
#     "type" => "agent_message", "content" => "...", ...,
#     "id" => 99, "action" => "create",
#     "evicted_message_ids" => [101, 102, 103]
#   }
#
# @example Update broadcast payload (e.g. token count arrives)
#   {
#     "type" => "user_message", "content" => "hello", ...,
#     "id" => 42, "action" => "update",
#     "rendered" => { "debug" => { "role" => "user", "content" => "hello", "tokens" => 15 } }
#   }
module Message::Broadcasting
  extend ActiveSupport::Concern

  ACTION_CREATE = "create"
  ACTION_UPDATE = "update"

  included do
    after_create_commit :broadcast_create
    after_update_commit :broadcast_update
  end

  private

  def broadcast_create
    broadcast_message(action: ACTION_CREATE)
  end

  def broadcast_update
    broadcast_message(action: ACTION_UPDATE)
  end

  # Decorates the message for the session's current view mode and broadcasts
  # the payload to the session's ActionCable stream. Includes viewport
  # eviction metadata so clients can remove messages the LLM has forgotten.
  #
  # @param action [String] ACTION_CREATE or ACTION_UPDATE — tells clients how to handle the message
  def broadcast_message(action:)
    return unless session_id

    session = Session.find_by(id: session_id)
    return unless session

    mode = session.view_mode
    decorator = MessageDecorator.for(self)
    broadcast_payload = payload.merge("id" => id, "action" => action)
    broadcast_payload["api_metrics"] = api_metrics if api_metrics.present?

    if decorator
      broadcast_payload["rendered"] = {mode => decorator.render(mode)}
    end

    evicted_ids = session.recalculate_viewport!
    broadcast_payload["evicted_message_ids"] = evicted_ids if evicted_ids.any?

    # The nil? branch fires on every broadcast until boundary initializes, but
    # schedule_mneme! returns early after setting the boundary — cost is one DB read + write.
    session.schedule_mneme! if evicted_ids.any? || session.mneme_boundary_message_id.nil?

    ActionCable.server.broadcast("session_#{session_id}", broadcast_payload)
  end
end
