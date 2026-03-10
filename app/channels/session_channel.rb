# frozen_string_literal: true

# Streams events for a specific session to connected clients.
# Part of the Brain/TUI separation: the Brain broadcasts events through
# this channel, and any number of clients (TUI, web, API) can subscribe.
#
# On subscription, sends the session's chat history so the client can
# render previous messages without a separate API call.
#
# @example Client subscribes to a session
#   App.cable.subscriptions.create({ channel: "SessionChannel", session_id: 42 })
class SessionChannel < ApplicationCable::Channel
  # Subscribes the client to the session-specific stream.
  # Rejects the subscription if no valid session_id is provided.
  # Transmits chat history to the subscribing client after confirmation.
  #
  # @param params [Hash] must include :session_id (positive integer)
  def subscribed
    session_id = params[:session_id].to_i
    if session_id > 0
      stream_from stream_name
      transmit_history
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

  # Processes user input: persists the message and enqueues LLM processing.
  #
  # @param data [Hash] must include "content" with the user's message text
  def speak(data)
    content = data["content"].to_s.strip
    session_id = params[:session_id].to_i
    return if content.empty? || !Session.exists?(session_id)

    Events::Bus.emit(Events::UserMessage.new(content: content, session_id: session_id))
    AgentRequestJob.perform_later(session_id)
  end

  # Returns recent sessions with metadata for session picker UI.
  #
  # @param data [Hash] optional "limit" (default 10, max 50)
  def list_sessions(data)
    limit = (data["limit"] || 10).to_i.clamp(1, 50)
    sessions = Session.order(updated_at: :desc).limit(limit).map do |session|
      {
        id: session.id,
        created_at: session.created_at.iso8601,
        updated_at: session.updated_at.iso8601,
        message_count: session.events.llm_messages.count
      }
    end
    transmit({"action" => "sessions_list", "sessions" => sessions})
  end

  # Creates a new session and switches the channel stream to it.
  # The client receives a session_changed signal followed by (empty) history.
  def create_session(_data)
    session = Session.create!
    switch_to_session(session.id)
  end

  # Switches the channel stream to an existing session.
  # The client receives a session_changed signal followed by chat history.
  #
  # @param data [Hash] must include "session_id" (positive integer)
  def switch_session(data)
    target_id = data["session_id"].to_i
    unless target_id > 0 && Session.exists?(target_id)
      transmit({"action" => "error", "message" => "Session not found"})
      return
    end

    switch_to_session(target_id)
  end

  private

  def stream_name
    "session_#{params[:session_id]}"
  end

  # Switches the channel to a different session: stops current stream,
  # updates the session reference, starts the new stream, and sends
  # a session_changed signal followed by chat history.
  def switch_to_session(new_id)
    stop_all_streams
    params[:session_id] = new_id
    stream_from stream_name
    session = Session.find(new_id)
    transmit({
      "action" => "session_changed",
      "session_id" => new_id,
      "message_count" => session.events.llm_messages.count
    })
    transmit_history
  end

  # Sends displayable events from the LLM's viewport to the subscribing
  # client. The TUI shows exactly what the agent can see — no more, no less.
  def transmit_history
    session = Session.find_by(id: params[:session_id])
    return unless session

    session.viewport_events.each do |event|
      next unless event.llm_message?

      transmit(event.payload)
    end
  end
end
