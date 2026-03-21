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
# When a new event pushes old events out of the LLM's context window,
# the broadcast includes `evicted_event_ids` so clients can remove
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
#     "evicted_event_ids" => [101, 102, 103]
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

  # Broadcasts this event immediately, bypassing +after_create_commit+.
  # Used inside a wrapping transaction where +after_create_commit+ is
  # deferred until the outer transaction commits. Gives clients
  # optimistic UI — the event appears right away and is removed via
  # bounce if the transaction rolls back.
  #
  # Sets a flag so the deferred +after_create_commit+ callback skips
  # the duplicate broadcast after the transaction commits.
  def broadcast_now!
    @already_broadcast = true
    broadcast_event(action: ACTION_CREATE)
  end

  private

  def broadcast_create
    return if @already_broadcast
    broadcast_event(action: ACTION_CREATE)
  end

  def broadcast_update
    broadcast_event(action: ACTION_UPDATE)
  end

  # Decorates the event for the session's current view mode and broadcasts
  # the payload to the session's ActionCable stream. Includes viewport
  # eviction metadata so clients can remove messages the LLM has forgotten.
  #
  # @param action [String] ACTION_CREATE or ACTION_UPDATE — tells clients how to handle the event
  def broadcast_event(action:)
    return unless session_id

    session = Session.find_by(id: session_id)
    return unless session

    mode = session.view_mode
    decorator = EventDecorator.for(self)
    broadcast_payload = payload.merge("id" => id, "action" => action)

    if decorator
      broadcast_payload["rendered"] = {mode => decorator.render(mode)}
    end

    evicted_ids = session.recalculate_viewport!
    broadcast_payload["evicted_event_ids"] = evicted_ids if evicted_ids.any?

    session.schedule_mneme! if evicted_ids.any? || session.mneme_boundary_event_id.nil?

    ActionCable.server.broadcast("session_#{session_id}", broadcast_payload)
  end
end
