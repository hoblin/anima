# frozen_string_literal: true

# Streams events for a specific session to connected clients.
# Clients subscribe with a session_id and receive all events broadcast to that session.
class SessionChannel < ApplicationCable::Channel
  def subscribed
    stream_from "session_#{params[:session_id]}"
  end

  # Receives messages from clients and broadcasts them to the session stream.
  def receive(data)
    ActionCable.server.broadcast("session_#{params[:session_id]}", data)
  end
end
