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

  private

  def stream_name
    "session_#{params[:session_id]}"
  end

  # Sends recent displayable events (user/agent messages) from the session
  # history directly to the subscribing client.
  def transmit_history
    session = Session.find_by(id: params[:session_id])
    return unless session

    session.events
      .where(event_type: %w[user_message agent_message])
      .order(:id)
      .last(200)
      .each { |event| transmit(event.payload) }
  end
end
