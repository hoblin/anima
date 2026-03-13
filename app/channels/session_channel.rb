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
  DEFAULT_LIST_LIMIT = 10
  MAX_LIST_LIMIT = 50

  # Subscribes the client to the session-specific stream.
  # Rejects the subscription if no valid session_id is provided.
  # Transmits the current view_mode and chat history to the subscribing client.
  #
  # @param params [Hash] must include :session_id (positive integer)
  def subscribed
    @current_session_id = params[:session_id].to_i
    if @current_session_id > 0
      stream_from stream_name
      transmit_view_mode
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
    return if content.empty? || !Session.exists?(@current_session_id)

    Events::Bus.emit(Events::UserMessage.new(content: content, session_id: @current_session_id))
    AgentRequestJob.perform_later(@current_session_id)
  end

  # Returns recent sessions with metadata for session picker UI.
  #
  # @param data [Hash] optional "limit" (default 10, max 50)
  def list_sessions(data)
    limit = (data["limit"] || DEFAULT_LIST_LIMIT).to_i.clamp(1, MAX_LIST_LIMIT)
    sessions = Session.recent(limit)
    counts = Event.where(session_id: sessions.select(:id)).llm_messages.group(:session_id).count

    result = sessions.map do |session|
      {
        id: session.id,
        created_at: session.created_at.iso8601,
        updated_at: session.updated_at.iso8601,
        message_count: counts[session.id] || 0
      }
    end
    transmit({"action" => "sessions_list", "sessions" => result})
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
    return transmit_error("Session not found") unless target_id > 0

    switch_to_session(target_id)
  rescue ActiveRecord::RecordNotFound
    transmit_error("Session not found")
  end

  # Changes the session's view mode and re-broadcasts the viewport.
  # All clients on the session receive the mode change and fresh history.
  #
  # @param data [Hash] must include "view_mode" (one of Session::VIEW_MODES)
  def change_view_mode(data)
    mode = data["view_mode"].to_s
    return transmit_error("Invalid view mode") unless Session::VIEW_MODES.include?(mode)

    session = Session.find(@current_session_id)
    session.update!(view_mode: mode)

    ActionCable.server.broadcast(stream_name, {"action" => "view_mode_changed", "view_mode" => mode})
    broadcast_viewport(session)
  rescue ActiveRecord::RecordNotFound
    transmit_error("Session not found")
  end

  private

  def stream_name
    "session_#{@current_session_id}"
  end

  # Switches the channel to a different session: stops current stream,
  # updates the session reference, starts the new stream, and sends
  # a session_changed signal followed by chat history.
  def switch_to_session(new_id)
    stop_all_streams
    @current_session_id = new_id
    stream_from stream_name
    session = Session.find(new_id)
    transmit({
      "action" => "session_changed",
      "session_id" => new_id,
      "message_count" => session.events.llm_messages.count,
      "view_mode" => session.view_mode
    })
    transmit_history
  end

  # Transmits the current view_mode so the TUI initializes correctly.
  # Sends `{action: "view_mode", view_mode: <mode>}` to the subscribing client.
  # @return [void]
  def transmit_view_mode
    session = Session.find_by(id: @current_session_id)
    return unless session

    transmit({"action" => "view_mode", "view_mode" => session.view_mode})
  end

  # Sends decorated context events (messages + tool interactions) from
  # the LLM's viewport to the subscribing client. Each event is wrapped
  # in an {EventDecorator} and the pre-rendered output is included in
  # the transmitted payload. Tool events are included so the TUI can
  # reconstruct tool call counters on reconnect.
  # In debug mode, prepends the assembled system prompt as a special block.
  def transmit_history
    session = Session.find_by(id: @current_session_id)
    return unless session

    transmit_system_prompt(session) if session.view_mode == "debug"

    session.viewport_events.each do |event|
      transmit(decorate_event_payload(event, session.view_mode))
    end
  end

  # Broadcasts the re-decorated viewport to all clients on the session stream.
  # Used after a view mode change to refresh all connected clients.
  # In debug mode, prepends the assembled system prompt as a special block.
  # @param session [Session] the session whose viewport to broadcast
  # @return [void]
  def broadcast_viewport(session)
    broadcast_system_prompt(session) if session.view_mode == "debug"

    session.viewport_events.each do |event|
      ActionCable.server.broadcast(stream_name, decorate_event_payload(event, session.view_mode))
    end
  end

  def decorate_event_payload(event, mode = "basic")
    payload = event.payload.merge("id" => event.id)
    decorator = EventDecorator.for(event)
    return payload unless decorator

    payload.merge("rendered" => {mode => decorator.render(mode)})
  end

  # Transmits the assembled system prompt to the subscribing client.
  # Skipped when the session has no system prompt configured.
  # @param session [Session]
  # @return [void]
  def transmit_system_prompt(session)
    payload = system_prompt_payload(session)
    return unless payload

    transmit(payload)
  end

  # Broadcasts the assembled system prompt to all clients on the stream.
  # Skipped when the session has no system prompt configured.
  # @param session [Session]
  # @return [void]
  def broadcast_system_prompt(session)
    payload = system_prompt_payload(session)
    return unless payload

    ActionCable.server.broadcast(stream_name, payload)
  end

  # Builds the system prompt payload for debug mode transmission.
  # @param session [Session]
  # @return [Hash, nil] the system prompt payload, or nil if no prompt
  def system_prompt_payload(session)
    prompt = session.system_prompt
    return unless prompt

    tokens = [(prompt.bytesize / Event::BYTES_PER_TOKEN.to_f).ceil, 1].max
    {
      "type" => "system_prompt",
      "rendered" => {
        "debug" => {role: :system_prompt, content: prompt, tokens: tokens, estimated: true}
      }
    }
  end

  def transmit_error(message)
    transmit({"action" => "error", "message" => message})
  end
end
