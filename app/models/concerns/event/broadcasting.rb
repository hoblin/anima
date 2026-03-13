# frozen_string_literal: true

# Broadcasts Event records to connected WebSocket clients via ActionCable.
# Follows the Turbo Streams pattern: events are broadcast on both create
# and update, with an action type so clients can distinguish append from
# replace operations.
#
# Each broadcast includes the Event's database ID, enabling clients to
# maintain an ID-indexed store for efficient in-place updates (e.g. when
# token counts arrive asynchronously from {CountEventTokensJob}).
#
# @example Create broadcast payload
#   {
#     "type" => "user_message", "content" => "hello", ...,
#     "id" => 42, "action" => "create",
#     "rendered" => { "basic" => { "role" => "user", "content" => "hello" } }
#   }
#
# @example Update broadcast payload (e.g. token count arrives)
#   {
#     "type" => "user_message", "content" => "hello", ...,
#     "id" => 42, "action" => "update",
#     "rendered" => { "debug" => { "role" => "user", "content" => "hello", "tokens" => 15 } }
#   }
module Event::Broadcasting
  extend ActiveSupport::Concern

  ACTION_CREATE = "create"
  ACTION_UPDATE = "update"

  included do
    after_create_commit :broadcast_create
    after_update_commit :broadcast_update
  end

  private

  def broadcast_create
    broadcast_event(action: ACTION_CREATE)
  end

  def broadcast_update
    broadcast_event(action: ACTION_UPDATE)
  end

  # Decorates the event for the session's current view mode and broadcasts
  # the payload to the session's ActionCable stream.
  #
  # @param action [String] ACTION_CREATE or ACTION_UPDATE — tells clients how to handle the event
  def broadcast_event(action:)
    return unless session_id

    mode = Session.where(id: session_id).pick(:view_mode) || "basic"
    decorator = EventDecorator.for(self)
    broadcast_payload = payload.merge("id" => id, "action" => action)

    if decorator
      broadcast_payload["rendered"] = {mode => decorator.render(mode)}
    end

    ActionCable.server.broadcast("session_#{session_id}", broadcast_payload)
  end
end
