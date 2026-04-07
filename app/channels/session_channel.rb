# frozen_string_literal: true

# Streams messages for a specific session to connected clients.
# Part of the Brain/TUI separation: the Brain broadcasts messages through
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

  # Processes user input. For idle sessions, persists the message immediately
  # so it appears in the TUI without waiting for the background job, then
  # schedules {AgentRequestJob} for LLM delivery. If delivery fails, the
  # job deletes the message and emits a {Events::BounceBack}.
  #
  # For busy sessions, stages the message as a {PendingMessage} in a
  # separate table until the current agent loop completes.
  #
  # @param data [Hash] must include "content" with the user's message text
  # @see Session#enqueue_user_message
  def speak(data)
    content = data["content"].to_s.strip
    return if content.empty?

    session = Session.find_by(id: @current_session_id)
    return unless session

    session.enqueue_user_message(content, bounce_back: true)
  end

  # Recalls the most recent pending message for editing. Deletes the
  # {PendingMessage} — its +after_destroy_commit+ broadcasts removal
  # so all clients remove the pending indicator.
  #
  # @param data [Hash] must include "pending_message_id" (positive integer)
  def recall_pending(data)
    pm_id = data["pending_message_id"].to_i
    return if pm_id <= 0

    pm = PendingMessage.find_by(id: pm_id, session_id: @current_session_id)
    pm&.destroy!
  end

  # Requests interruption of the current tool execution. Sets a flag on the
  # session that the LLM client checks between tool calls. Remaining tools
  # receive synthetic "Your human wants your attention" results to satisfy the API's
  # tool_use/tool_result pairing requirement.
  #
  # Cascades to running sub-agent sessions to avoid burning tokens in
  # child jobs that the parent will discard anyway.
  #
  # Atomic: a single UPDATE with WHERE avoids the read-then-write race where
  # the session could finish processing between the SELECT and UPDATE.
  # No-op if the session isn't currently processing.
  #
  # @param _data [Hash] unused
  def interrupt_execution(_data)
    updated = Session.where(id: @current_session_id, processing: true)
      .update_all(interrupt_requested: true)

    return unless updated > 0

    Session.processing_children_of(@current_session_id)
      .update_all(interrupt_requested: true)

    Session.find_by(id: @current_session_id)&.broadcast_session_state("interrupting")
    ActionCable.server.broadcast(stream_name, {"action" => "interrupt_acknowledged"})
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
    counts = Message.where(session_id: all_ids).llm_messages.group(:session_id).count

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

  # Validates and saves an Anthropic subscription token to encrypted storage.
  # Format-validated and API-validated before storage. The token never enters the
  # LLM context window — it flows directly from WebSocket to the secrets table.
  #
  # @param data [Hash] must include "token" (Anthropic subscription token string)
  def save_token(data)
    token = data["token"].to_s.strip

    Providers::Anthropic.validate_token_format!(token)

    warning = begin
      Providers::Anthropic.validate_token_api!(token)
      nil
    rescue Providers::Anthropic::TransientError => transient
      # Token format is valid but API is temporarily unavailable (500, timeout, etc.).
      # Save the token to break the prompt loop — it will work once the API recovers.
      "Token saved but could not be verified — #{transient.message}"
    end

    write_anthropic_token(token)
    transmit({"action" => "token_saved", "warning" => warning}.compact)
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
  # Payload: session_id, name, agent_name, parent_session_id, message_count,
  # view_mode, active_skills, goals, children (when present).
  #
  # @param session [Session] the session to announce
  # @return [void]
  def transmit_session_changed(session)
    payload = {
      "action" => "session_changed",
      "session_id" => session.id,
      "name" => session.name,
      "agent_name" => Anima::Settings.agent_name,
      "parent_session_id" => session.parent_session_id,
      "message_count" => session.messages.llm_messages.count,
      "view_mode" => session.view_mode,
      "active_skills" => session.active_skills,
      "active_workflow" => session.active_workflow,
      "goals" => session.goals_summary
    }

    children = session.child_sessions.order(:created_at).select(:id, :name, :processing)
    if children.any?
      payload["children"] = children.map { |child|
        state = child.processing? ? "llm_generating" : "idle"
        {"id" => child.id, "name" => child.name, "processing" => child.processing?, "session_state" => state}
      }
    end

    transmit(payload)
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

  # Sends decorated context messages (conversation + tool interactions) from
  # the LLM's viewport to the subscribing client. Each message is wrapped
  # in a {MessageDecorator} and the pre-rendered output is included in
  # the transmitted payload. Tool messages are included so the TUI can
  # reconstruct tool call counters on reconnect.
  # In debug mode, prepends the assembled system prompt as a special block.
  # Pending messages are sent last so the TUI shows them at the bottom.
  #
  # Snapshots the viewport so subsequent message broadcasts can compute
  # eviction diffs accurately.
  #
  # @param session [Session] the session whose history to transmit
  def transmit_history(session)
    transmit_system_prompt(session) if session.view_mode == "debug"

    each_viewport_message(session) do |_msg, msg_payload|
      transmit(msg_payload)
    end

    session.pending_messages.find_each do |pm|
      transmit({"action" => "pending_message_created", "pending_message_id" => pm.id, "content" => pm.content})
    end
  end

  # Broadcasts the re-decorated viewport to all clients on the session stream.
  # Used after a view mode change to refresh all connected clients.
  # In debug mode, prepends the assembled system prompt as a special block.
  # Pending messages are sent last so the TUI shows them at the bottom.
  #
  # Snapshots the viewport so subsequent message broadcasts can compute
  # eviction diffs accurately.
  #
  # @param session [Session] the session whose viewport to broadcast
  # @return [void]
  def broadcast_viewport(session)
    broadcast_system_prompt(session) if session.view_mode == "debug"

    each_viewport_message(session) do |_msg, msg_payload|
      ActionCable.server.broadcast(stream_name, msg_payload)
    end

    session.pending_messages.find_each do |pm|
      ActionCable.server.broadcast(stream_name, {"action" => "pending_message_created", "pending_message_id" => pm.id, "content" => pm.content})
    end
  end

  # Loads the viewport and yields each message with its decorated payload
  # in newest-first order. Newest-first prevents render thrashing during
  # session switches: the most recent messages fill the visible viewport
  # immediately, while older messages are inserted above the fold without
  # visual disruption.
  #
  # @param session [Session] the session whose viewport to iterate
  # @yieldparam message [Message] the persisted message record
  # @yieldparam payload [Hash] decorated payload ready for transmission
  # @return [void]
  def each_viewport_message(session)
    session.viewport_messages.reverse_each do |msg|
      yield msg, decorate_message_payload(msg, session.view_mode)
    end
  end

  # Decorates a message for transmission to clients. Merges the message's
  # database ID and structured decorator output into the payload.
  # Used by {#transmit_history} and {#broadcast_viewport} for historical
  # and viewport re-broadcast — live broadcasts use {Message::Broadcasting}.
  #
  # @param message [Message] persisted message record
  # @param mode [String] view mode for decoration (default: "basic")
  # @return [Hash] payload with "id" and optional "rendered" key
  def decorate_message_payload(message, mode = "basic")
    payload = message.payload.merge("id" => message.id)
    decorator = MessageDecorator.for(message)
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
  # Delegates to {Session.system_prompt_payload} for the shared format.
  # Includes deterministic tool schemas (standard + spawn tools).
  # MCP tools appear after the first LLM request via live broadcast.
  # @param session [Session]
  # @return [Hash, nil] the system prompt payload, or nil if no prompt
  def system_prompt_payload(session)
    prompt = session.system_prompt
    return unless prompt

    Session.system_prompt_payload(prompt, tools: session.tool_schemas)
  end

  # Writes the Anthropic subscription token to encrypted storage.
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
