# frozen_string_literal: true

# Streams events for a specific session to connected clients.
# Part of the Brain/TUI separation: the Brain broadcasts events through
# this channel, and any number of clients (TUI, web, API) can subscribe.
#
# @example Client subscribes to a session
#   App.cable.subscriptions.create({ channel: "SessionChannel", session_id: 42 })
class SessionChannel < ApplicationCable::Channel
  # Subscribes the client to the session-specific stream.
  # Rejects the subscription if no valid session_id is provided.
  #
  # @param params [Hash] must include :session_id (positive integer)
  def subscribed
    session_id = params[:session_id].to_i
    if session_id > 0
      stream_from stream_name
    else
      reject
    end
  end

  # Receives messages from clients and broadcasts them to all session subscribers.
  #
  # @param data [Hash] arbitrary message payload
  def receive(data)
    ActionCable.server.broadcast(stream_name, data)
  end

  private

  def stream_name
    "session_#{params[:session_id]}"
  end
end
