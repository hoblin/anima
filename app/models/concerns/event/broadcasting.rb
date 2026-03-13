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
# @example Broadcast payload shape
#   {
#     "type" => "user_message", "content" => "hello", ...,
#     "id" => 42, "action" => "create",
#     "rendered" => { "basic" => { "role" => "user", "content" => "hello" } }
#   }
module Event::Broadcasting
  extend ActiveSupport::Concern

  included do
    after_create_commit :broadcast_create
    after_update_commit :broadcast_update
  end

  private

  def broadcast_create
    broadcast_event(action: "create")
  end

  def broadcast_update
    broadcast_event(action: "update")
  end

  # Decorates the event for the session's current view mode and broadcasts
  # the payload to the session's ActionCable stream.
  #
  # @param action [String] "create" or "update" — tells clients how to handle the event
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
