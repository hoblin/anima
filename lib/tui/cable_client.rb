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
  # Automatically reconnects with exponential backoff when the connection
  # drops unexpectedly. Detects stale connections via Action Cable ping
  # heartbeat monitoring.
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
    CONNECTION_TIMEOUT = 10 # seconds to wait for the connecting state to advance
    MAX_RECONNECT_ATTEMPTS = 10
    BACKOFF_BASE = 1.0 # initial backoff delay in seconds
    BACKOFF_CAP = 30.0 # maximum backoff delay
    PING_STALE_THRESHOLD = 6.0 # seconds without ping before connection is stale

    # @return [String] brain server host:port
    attr_reader :host

    # @return [Integer] current session ID
    attr_reader :session_id

    # @return [Symbol] connection status (:disconnected, :connecting, :connected, :subscribed, :reconnecting)
    attr_reader :status

    # @return [Integer] current reconnection attempt (0 when connected)
    attr_reader :reconnect_attempt

    # @param host [String] brain server address (e.g. "localhost:42134")
    # @param session_id [Integer] session to subscribe to
    def initialize(host:, session_id:)
      @host = host
      @session_id = session_id
      @subscribed_session_id = session_id
      @status = :disconnected
      @message_queue = Thread::Queue.new
      @mutex = Mutex.new
      @ws = nil
      @ws_thread = nil
      @intentional_disconnect = false
      @reconnect_attempt = 0
      @last_ping_at = nil
      @connection_generation = 0
    end

    # Opens the WebSocket connection in a background thread.
    # The connection subscribes to the session channel automatically
    # after receiving the Action Cable welcome message. Reconnects
    # automatically on unexpected disconnection.
    def connect
      @mutex.synchronize do
        @intentional_disconnect = false
        @status = :connecting
      end
      @ws_thread = Thread.new { run_websocket_loop }
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

    # Requests the brain to change the session's view mode.
    # The server broadcasts view_mode_changed to all clients on the session,
    # followed by the re-decorated viewport.
    #
    # @param mode [String] one of "basic", "verbose", "debug"
    # @return [void]
    def change_view_mode(mode)
      send_action("change_view_mode", {"view_mode" => mode})
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

    # Closes the WebSocket connection and cleans up the background thread.
    # Prevents automatic reconnection.
    def disconnect
      @mutex.synchronize do
        @intentional_disconnect = true
        @status = :disconnected
      end
      @ws&.close
      @ws_thread&.join(DISCONNECT_TIMEOUT)
    end

    private

    # Main connection loop: connect -> monitor -> reconnect if needed.
    # Runs in a background thread spawned by {#connect}.
    def run_websocket_loop
      loop do
        return if intentional_disconnect?

        if open_websocket
          monitor_connection
        end

        return if intentional_disconnect?
        break unless schedule_reconnect
      end
    rescue => _e
      on_disconnected
    end

    # Establishes WebSocket connection and registers event handlers.
    #
    # @return [Boolean] true if connection was opened, false on failure
    def open_websocket
      begin
        @ws&.close
      rescue IOError, Errno::ECONNRESET
        nil
      end

      generation = @mutex.synchronize do
        @connection_generation += 1
        @status = :connecting
        @last_ping_at = nil
        @connection_generation
      end

      url = "ws://#{@host}/cable"
      client = self

      @ws = WebSocket::Client::Simple.connect(url, headers: {
        "Sec-WebSocket-Protocol" => "actioncable-v1-json"
      })

      @ws.on :open do
        # Wait for welcome message from Action Cable
      end

      @ws.on :message do |msg|
        next if client.send(:stale_generation?, generation)
        data = JSON.parse(msg.data)
        client.send(:handle_protocol_message, data)
      rescue JSON::ParserError
        # Ignore malformed messages
      end

      @ws.on :close do |_e|
        client.send(:on_disconnected) unless client.send(:stale_generation?, generation)
      end

      @ws.on :error do |_e|
        client.send(:on_disconnected) unless client.send(:stale_generation?, generation)
      end

      true
    rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::EHOSTUNREACH,
      SocketError, IOError => _e
      false
    end

    # Polls connection status until disconnect is detected.
    # Also monitors for stale connections and connection timeout.
    def monitor_connection
      connection_start = Time.now

      loop do
        break if @status == :disconnected

        if @status == :connecting && (Time.now - connection_start) > CONNECTION_TIMEOUT
          on_disconnected
          break
        end

        check_stale_connection
        sleep POLL_INTERVAL
      end
    end

    # Detects stale connections by monitoring ping heartbeat interval.
    # Action Cable sends pings approximately every 3 seconds;
    # a 6-second gap indicates 2 missed pings.
    def check_stale_connection
      stale = @mutex.synchronize do
        next false unless @last_ping_at && @status == :subscribed
        (Time.now - @last_ping_at) >= PING_STALE_THRESHOLD
      end

      on_disconnected if stale
    end

    # Waits with exponential backoff before next reconnection attempt.
    #
    # @return [Boolean] true if reconnection should proceed, false if max attempts reached
    def schedule_reconnect
      attempt = @mutex.synchronize do
        @reconnect_attempt += 1
        @reconnect_attempt
      end

      if attempt > MAX_RECONNECT_ATTEMPTS
        @mutex.synchronize { @status = :disconnected }
        @message_queue << {
          "type" => "connection",
          "status" => "failed",
          "message" => "Reconnection failed after #{MAX_RECONNECT_ATTEMPTS} attempts"
        }
        return false
      end

      delay = backoff_delay(attempt)
      @mutex.synchronize { @status = :reconnecting }
      @message_queue << {
        "type" => "connection",
        "status" => "reconnecting",
        "attempt" => attempt,
        "max_attempts" => MAX_RECONNECT_ATTEMPTS,
        "delay" => delay.round(1)
      }

      sleep delay
      !intentional_disconnect?
    end

    # Full jitter backoff: random delay between 0 and min(cap, base * 2^attempt).
    # Prevents thundering herd when multiple clients reconnect simultaneously.
    #
    # @param attempt [Integer] current attempt number (1-based)
    # @return [Float] delay in seconds
    def backoff_delay(attempt)
      max_delay = [BACKOFF_CAP, BACKOFF_BASE * (2**(attempt - 1))].min
      rand(0.0..max_delay)
    end

    # Checks if a captured connection generation is outdated.
    # WebSocket event handlers capture the generation at connection time;
    # if a new connection starts, older handlers must ignore their events
    # to prevent stale callbacks from corrupting current state.
    #
    # @param generation [Integer] the generation captured by an event handler
    # @return [Boolean] true if the given generation is no longer current
    def stale_generation?(generation)
      @mutex.synchronize { generation != @connection_generation }
    end

    # @return [Boolean] true if disconnect was initiated by the application
    def intentional_disconnect?
      @mutex.synchronize { @intentional_disconnect }
    end

    def handle_protocol_message(data)
      case data["type"]
      when "welcome"
        @mutex.synchronize { @status = :connected }
        @last_ping_at = Time.now
        subscribe
      when "ping"
        @last_ping_at = Time.now
      when "confirm_subscription"
        @mutex.synchronize do
          @status = :subscribed
          @reconnect_attempt = 0
        end
        @message_queue << {"type" => "connection", "status" => "subscribed"}
      when "reject_subscription"
        on_disconnected
        @message_queue << {"type" => "connection", "status" => "rejected"}
      when "disconnect"
        if data["reconnect"] == false
          @mutex.synchronize do
            @intentional_disconnect = true
            @status = :disconnected
          end
          @message_queue << {"type" => "connection", "status" => "disconnected"}
        else
          on_disconnected
        end
      else
        # Regular broadcast or transmit from the channel
        if data["message"]
          @message_queue << data["message"]
        end
      end
    end

    # Transitions to disconnected state. Guards against duplicate calls
    # from concurrent close/error handlers.
    def on_disconnected
      @mutex.synchronize do
        return if @status == :disconnected || @status == :reconnecting
        @status = :disconnected
      end
      @message_queue << {"type" => "connection", "status" => "disconnected"}
    end

    def subscribe
      sid = @mutex.synchronize { @session_id }
      @mutex.synchronize { @subscribed_session_id = sid }
      identifier = {channel: "SessionChannel", session_id: sid}.to_json
      send_command("subscribe", identifier)
    end

    def send_action(action, data = {})
      payload = data.merge("action" => action).to_json

      @ws&.send({
        command: "message",
        identifier: subscription_identifier,
        data: payload
      }.to_json)
    end

    # Returns the identifier matching the active ActionCable subscription.
    # After session switches, @session_id changes but the subscription
    # identifier must match the one used during subscribe.
    def subscription_identifier
      sid = @mutex.synchronize { @subscribed_session_id }
      {channel: "SessionChannel", session_id: sid}.to_json
    end

    def send_command(command, identifier)
      @ws&.send({
        command: command,
        identifier: identifier
      }.to_json)
    end
  end
end
