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
  # When a valid session_id is provided, subscribes to that session.
  # When omitted or zero, resolves to the most recent session (creating
  # one if none exist) — this is the CQRS-compliant path where the
  # server owns session resolution instead of a REST endpoint.
  #
  # Always transmits a session_changed signal so the client learns
  # the authoritative session ID, followed by view_mode and history.
  #
  # @param params [Hash] optional :session_id (positive integer)
  def subscribed
    @current_session_id = resolve_session_id
    stream_from stream_name

    session = Session.find_by(id: @current_session_id)
    return unless session

    transmit_session_changed(session)
    transmit_view_mode(session)
    transmit_history(session)
  end

  # Receives messages from clients and broadcasts them to all session subscribers.
  #
  # @param data [Hash] arbitrary message payload
  def receive(data)
    ActionCable.server.broadcast(stream_name, data)
  end

  # Processes user input: persists the message and enqueues LLM processing.
  # When the session is actively processing an agent request, the message
  # is queued as "pending" and picked up after the current loop completes.
  #
  # @param data [Hash] must include "content" with the user's message text
  def speak(data)
    content = data["content"].to_s.strip
    return if content.empty?

    session = Session.find_by(id: @current_session_id)
    return unless session

    if session.processing?
      Events::Bus.emit(Events::UserMessage.new(content: content, session_id: @current_session_id, status: Event::PENDING_STATUS))
    else
      Events::Bus.emit(Events::UserMessage.new(content: content, session_id: @current_session_id))
      AgentRequestJob.perform_later(@current_session_id)
    end
  end

  # Recalls the most recent pending message for editing. Deletes the
  # pending event and broadcasts the recall so all clients remove it.
  #
  # @param data [Hash] must include "event_id" (positive integer)
  def recall_pending(data)
    event_id = data["event_id"].to_i
    return if event_id <= 0

    event = Event.find_by(
      id: event_id,
      session_id: @current_session_id,
      event_type: "user_message",
      status: Event::PENDING_STATUS
    )
    return unless event

    event.destroy!
    ActionCable.server.broadcast(stream_name, {"action" => "user_message_recalled", "event_id" => event_id})
  end

  # Requests interruption of the current tool execution. Sets a flag on the
  # session that the LLM client checks between tool calls. Remaining tools
  # receive synthetic "Stopped by user" results to satisfy the API's
  # tool_use/tool_result pairing requirement.
  #
  # No-op if the session isn't currently processing.
  #
  # @param _data [Hash] unused
  def interrupt_execution(_data)
    session = Session.find_by(id: @current_session_id)
    return unless session&.processing?

    session.update_column(:interrupt_requested, true)
  end

  # Returns recent root sessions with nested child metadata for session picker UI.
  # Filters to root sessions only (no parent_session_id). Child sessions are
  # nested under their parent with name and status information.
  #
  # @param data [Hash] optional "limit" (default 10, max 50)
  def list_sessions(data)
    limit = (data["limit"] || DEFAULT_LIST_LIMIT).to_i.clamp(1, MAX_LIST_LIMIT)
    sessions = Session.root_sessions.recent(limit).includes(:child_sessions)
    all_ids = sessions.flat_map { |session| [session.id] + session.child_sessions.map(&:id) }
    counts = Event.where(session_id: all_ids).llm_messages.group(:session_id).count

    result = sessions.map { |session| serialize_session_with_children(session, counts) }
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

  # Validates and saves an Anthropic subscription token to encrypted credentials.
  # Format-validated and API-validated before storage. The token never enters the
  # LLM context window — it flows directly from WebSocket to encrypted credentials.
  #
  # @param data [Hash] must include "token" (Anthropic subscription token string)
  def save_token(data)
    token = data["token"].to_s.strip

    Providers::Anthropic.validate_token_format!(token)
    Providers::Anthropic.validate_token_api!(token)
    write_anthropic_token(token)

    transmit({"action" => "token_saved"})
  rescue Providers::Anthropic::TokenFormatError, Providers::Anthropic::AuthenticationError => error
    transmit({"action" => "token_error", "message" => error.message})
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

  # Resolves the session to subscribe to. Uses the client-provided ID
  # when valid, otherwise falls back to the most recent session or
  # creates a new one.
  #
  # @return [Integer] resolved session ID
  def resolve_session_id
    id = params[:session_id].to_i
    return id if id > 0

    (Session.recent(1).first || Session.create!).id
  end

  # Transmits session metadata as a session_changed signal.
  # Used on initial subscription and after session switches so the
  # client can handle both paths with a single code path.
  #
  # Payload: session_id, name, parent_session_id, message_count,
  # view_mode, active_skills, goals.
  #
  # @param session [Session] the session to announce
  # @return [void]
  def transmit_session_changed(session)
    transmit({
      "action" => "session_changed",
      "session_id" => session.id,
      "name" => session.name,
      "parent_session_id" => session.parent_session_id,
      "message_count" => session.events.llm_messages.count,
      "view_mode" => session.view_mode,
      "active_skills" => session.active_skills,
      "active_workflow" => session.active_workflow,
      "goals" => session.goals_summary
    })
  end

  # Switches the channel to a different session: stops current stream,
  # updates the session reference, starts the new stream, and sends
  # a session_changed signal followed by chat history.
  def switch_to_session(new_id)
    stop_all_streams
    @current_session_id = new_id
    stream_from stream_name

    session = Session.find(new_id)
    transmit_session_changed(session)
    transmit_history(session)
  end

  # Transmits the current view_mode so the TUI initializes correctly.
  # Sends `{action: "view_mode", view_mode: <mode>}` to the subscribing client.
  #
  # @param session [Session] the session whose view_mode to transmit
  # @return [void]
  def transmit_view_mode(session)
    transmit({"action" => "view_mode", "view_mode" => session.view_mode})
  end

  # Sends decorated context events (messages + tool interactions) from
  # the LLM's viewport to the subscribing client. Each event is wrapped
  # in an {EventDecorator} and the pre-rendered output is included in
  # the transmitted payload. Tool events are included so the TUI can
  # reconstruct tool call counters on reconnect.
  # In debug mode, prepends the assembled system prompt as a special block.
  #
  # Snapshots the viewport so subsequent event broadcasts can compute
  # eviction diffs accurately.
  #
  # @param session [Session] the session whose history to transmit
  def transmit_history(session)
    transmit_system_prompt(session) if session.view_mode == "debug"

    each_viewport_event(session) do |event, payload|
      transmit(payload)
    end
  end

  # Broadcasts the re-decorated viewport to all clients on the session stream.
  # Used after a view mode change to refresh all connected clients.
  # In debug mode, prepends the assembled system prompt as a special block.
  #
  # Snapshots the viewport so subsequent event broadcasts can compute
  # eviction diffs accurately.
  #
  # @param session [Session] the session whose viewport to broadcast
  # @return [void]
  def broadcast_viewport(session)
    broadcast_system_prompt(session) if session.view_mode == "debug"

    each_viewport_event(session) do |event, payload|
      ActionCable.server.broadcast(stream_name, payload)
    end
  end

  # Loads the viewport, snapshots it for eviction tracking, and yields
  # each event with its decorated payload. Snapshot uses snapshot_viewport!
  # (not recalculate_viewport!) because full viewport refreshes don't need
  # eviction diffs — clients clear their store before rendering.
  #
  # @param session [Session] the session whose viewport to iterate
  # @yieldparam event [Event] the persisted event record
  # @yieldparam payload [Hash] decorated payload ready for transmission
  # @return [void]
  def each_viewport_event(session)
    viewport = session.viewport_events
    session.snapshot_viewport!(viewport.map(&:id))

    viewport.each do |event|
      yield event, decorate_event_payload(event, session.view_mode)
    end
  end

  # Decorates an event for transmission to clients. Merges the event's
  # database ID and structured decorator output into the payload.
  # Used by {#transmit_history} and {#broadcast_viewport} for historical
  # and viewport re-broadcast — live broadcasts use {Event::Broadcasting}.
  #
  # @param event [Event] persisted event record
  # @param mode [String] view mode for decoration (default: "basic")
  # @return [Hash] payload with "id" and optional "rendered" key
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

  # Merges the Anthropic subscription token into encrypted credentials,
  # preserving existing keys (e.g. secret_key_base).
  #
  # @param token [String] validated Anthropic subscription token
  # @return [void]
  def write_anthropic_token(token)
    CredentialStore.write("anthropic", "subscription_token" => token)
  end

  # Serializes a root session with its children for the sessions_list response.
  # Includes a :children key only when the session has child sessions.
  #
  # @param session [Session] root session to serialize
  # @param counts [Hash<Integer, Integer>] session_id => llm_message count
  # @return [Hash] with :id, :created_at, :updated_at, :message_count, and optional :children
  def serialize_session_with_children(session, counts)
    entry = {
      id: session.id,
      name: session.name,
      created_at: session.created_at.iso8601,
      updated_at: session.updated_at.iso8601,
      message_count: counts[session.id] || 0
    }

    children = session.child_sessions.sort_by(&:created_at)
    return entry unless children.any?

    entry[:children] = children.map do |child|
      {
        id: child.id,
        name: child.name,
        processing: child.processing?,
        message_count: counts[child.id] || 0,
        created_at: child.created_at.iso8601
      }
    end

    entry
  end

  def transmit_error(message)
    transmit({"action" => "error", "message" => message})
  end
end
