# frozen_string_literal: true

require "websocket-client-simple"
require "json"

module TUI
  # Action Cable WebSocket client for connecting the TUI to the brain server.
  # Runs the WebSocket connection in a background thread and exposes a
  # thread-safe message queue for the TUI render loop to drain.
  #
  # Implements the +actioncable-v1-json+ protocol: subscribe to a
  # {SessionChannel}, receive event broadcasts, and send user input
  # via the +speak+ action.
  #
  # @example
  #   client = TUI::CableClient.new(host: "localhost:42134", session_id: 1)
  #   client.connect
  #   client.speak("Hello!")
  #   messages = client.drain_messages
  #   client.disconnect
  class CableClient
    DISCONNECT_TIMEOUT = 2 # seconds to wait for WebSocket thread to finish
    POLL_INTERVAL = 0.1 # seconds between connection status checks

    # @return [String] brain server host:port
    attr_reader :host

    # @return [Integer] current session ID
    attr_reader :session_id

    # @return [Symbol] connection status (:disconnected, :connecting, :connected, :subscribed)
    attr_reader :status

    # @param host [String] brain server address (e.g. "localhost:42134")
    # @param session_id [Integer] session to subscribe to
    def initialize(host:, session_id:)
      @host = host
      @session_id = session_id
      @status = :disconnected
      @message_queue = Thread::Queue.new
      @mutex = Mutex.new
      @ws = nil
      @ws_thread = nil
    end

    # Opens the WebSocket connection in a background thread.
    # The connection subscribes to the session channel automatically
    # after receiving the Action Cable welcome message.
    def connect
      @mutex.synchronize { @status = :connecting }
      @ws_thread = Thread.new { run_websocket }
    end

    # Sends user input to the brain for processing.
    #
    # @param content [String] the user's message text
    def speak(content)
      send_action("speak", {"content" => content})
    end

    # Requests the brain to create a new session and switch to it.
    # The server responds with a session_changed message followed by history.
    def create_session
      send_action("create_session", {})
    end

    # Requests the brain to switch to an existing session.
    # The server responds with a session_changed message followed by history.
    #
    # @param session_id [Integer] target session to resume
    def switch_session(session_id)
      send_action("switch_session", {"session_id" => session_id})
    end

    # Requests a list of recent sessions from the brain.
    # The server responds with a sessions_list message.
    #
    # @param limit [Integer] max sessions to return (default 10)
    def list_sessions(limit: 10)
      send_action("list_sessions", {"limit" => limit})
    end

    # Updates the local session ID reference after a server-side session switch.
    #
    # @param new_id [Integer] the new session ID
    def update_session_id(new_id)
      @mutex.synchronize { @session_id = new_id }
    end

    # Drains all pending messages from the queue (non-blocking).
    # Call this from the TUI render loop to process incoming events.
    #
    # @return [Array<Hash>] messages received since last drain
    def drain_messages
      messages = []
      loop do
        messages << @message_queue.pop(true)
      rescue ThreadError
        break
      end
      messages
    end

    # Unsubscribes from the current session and subscribes to a new one.
    #
    # @deprecated Use {#create_session} or {#switch_session} instead.
    #   The server now handles stream switching via the session protocol.
    # @param new_session_id [Integer] session to switch to
    def resubscribe(new_session_id)
      unsubscribe_current
      @mutex.synchronize { @session_id = new_session_id }
      subscribe
    end

    # Closes the WebSocket connection and cleans up the background thread.
    def disconnect
      @mutex.synchronize { @status = :disconnected }
      @ws&.close
      @ws_thread&.join(DISCONNECT_TIMEOUT)
    end

    private

    def run_websocket
      url = "ws://#{@host}/cable"
      client = self

      @ws = WebSocket::Client::Simple.connect(url, headers: {
        "Sec-WebSocket-Protocol" => "actioncable-v1-json"
      })

      @ws.on :open do
        # Wait for welcome message from Action Cable
      end

      @ws.on :message do |msg|
        data = JSON.parse(msg.data)
        client.send(:handle_protocol_message, data)
      rescue JSON::ParserError
        # Ignore malformed messages
      end

      @ws.on :close do |_e|
        client.send(:on_disconnected)
      end

      @ws.on :error do |_e|
        client.send(:on_disconnected)
      end

      # Keep thread alive while connected
      sleep POLL_INTERVAL while @status != :disconnected
    rescue => _e
      on_disconnected
    end

    def handle_protocol_message(data)
      case data["type"]
      when "welcome"
        @mutex.synchronize { @status = :connected }
        subscribe
      when "ping"
        # Heartbeat — connection alive
      when "confirm_subscription"
        @mutex.synchronize { @status = :subscribed }
        @message_queue << {"type" => "connection", "status" => "subscribed"}
      when "reject_subscription"
        on_disconnected
        @message_queue << {"type" => "connection", "status" => "rejected"}
      when "disconnect"
        on_disconnected
      else
        # Regular broadcast or transmit from the channel
        if data["message"]
          @message_queue << data["message"]
        end
      end
    end

    def subscribe
      identifier = {channel: "SessionChannel", session_id: @session_id}.to_json
      send_command("subscribe", identifier)
    end

    def unsubscribe_current
      identifier = {channel: "SessionChannel", session_id: @session_id}.to_json
      send_command("unsubscribe", identifier)
    end

    def send_action(action, data = {})
      identifier = {channel: "SessionChannel", session_id: @session_id}.to_json
      payload = data.merge("action" => action).to_json

      @ws&.send({
        command: "message",
        identifier: identifier,
        data: payload
      }.to_json)
    end

    def send_command(command, identifier)
      @ws&.send({
        command: command,
        identifier: identifier
      }.to_json)
    end

    def on_disconnected
      @mutex.synchronize { @status = :disconnected }
      @message_queue << {"type" => "connection", "status" => "disconnected"}
    end
  end
end
