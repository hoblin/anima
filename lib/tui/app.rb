# frozen_string_literal: true

require_relative "cable_client"
require_relative "message_store"
require_relative "screens/chat"

module TUI
  class App
    SCREENS = %i[chat].freeze

    COMMAND_KEYS = {
      "n" => :new_session,
      "v" => :view_mode,
      "q" => :quit
    }.freeze

    MENU_LABELS = COMMAND_KEYS.map { |key, action| "[#{key}] #{action.to_s.tr("_", " ").capitalize}" }.freeze

    SIDEBAR_WIDTH = 28

    # Connection status display styles
    STATUS_STYLES = {
      disconnected: {label: " DISCONNECTED ", fg: "white", bg: "red"},
      connecting: {label: " CONNECTING ", fg: "black", bg: "yellow"},
      connected: {label: " CONNECTED ", fg: "black", bg: "yellow"},
      subscribed: {label: " CONNECTED ", fg: "black", bg: "green"},
      reconnecting: {label: " RECONNECTING ", fg: "black", bg: "yellow"}
    }.freeze

    # Signals that trigger graceful shutdown when received from the OS.
    SHUTDOWN_SIGNALS = %w[HUP TERM INT].freeze

    # How often the watchdog thread checks if the controlling terminal is alive.
    # @see #terminal_watchdog_loop
    TERMINAL_CHECK_INTERVAL = 0.5

    # Unix controlling terminal device path.
    # @see #terminal_watchdog_loop
    CONTROLLING_TERMINAL = "/dev/tty"

    # Grace period for watchdog thread to exit before force-killing it.
    WATCHDOG_SHUTDOWN_TIMEOUT = 1

    attr_reader :current_screen, :command_mode
    # @return [Boolean] true when graceful shutdown has been requested via signal
    attr_reader :shutdown_requested

    # @param cable_client [TUI::CableClient] WebSocket client connected to the brain
    def initialize(cable_client:)
      @cable_client = cable_client
      @current_screen = :chat
      @command_mode = false
      @shutdown_requested = false
      @previous_signal_handlers = {}
      @watchdog_thread = nil
      @screens = {
        chat: Screens::Chat.new(cable_client: cable_client)
      }
    end

    def run
      install_signal_handlers
      start_terminal_watchdog
      RatatuiRuby.run do |tui|
        loop do
          break if @shutdown_requested

          tui.draw { |frame| render(frame, tui) }

          event = tui.poll_event(timeout: 0.1)
          break if @shutdown_requested
          next if event.nil? || event.none?
          break if handle_event(event) == :quit
        end
      end
    ensure
      stop_terminal_watchdog
      restore_signal_handlers
      @cable_client.disconnect
    end

    private

    def render(frame, tui)
      content_area, sidebar = tui.split(
        frame.area,
        direction: :horizontal,
        constraints: [
          tui.constraint_fill(1),
          tui.constraint_length(SIDEBAR_WIDTH)
        ]
      )

      @screens[@current_screen].render(frame, content_area, tui)
      render_sidebar(frame, sidebar, tui)
    end

    def render_sidebar(frame, area, tui)
      if @command_mode
        render_menu(frame, area, tui)
      else
        render_info(frame, area, tui)
      end
    end

    def render_menu(frame, area, tui)
      menu = tui.list(
        items: MENU_LABELS,
        block: tui.block(
          title: "Command",
          borders: [:all],
          border_type: :rounded,
          border_style: {fg: "yellow"}
        )
      )
      frame.render_widget(menu, area)
    end

    def render_info(frame, area, tui)
      session = @screens[:chat].session_info
      view_mode = @screens[:chat].view_mode

      mode_label = view_mode.capitalize
      mode_color = case view_mode
      when "verbose" then "yellow"
      when "debug" then "magenta"
      else "cyan"
      end

      lines = [
        tui.line(spans: [
          tui.span(content: "Anima v#{Anima::VERSION}", style: tui.style(fg: "white"))
        ]),
        tui.line(spans: [tui.span(content: "")]),
        tui.line(spans: [
          tui.span(content: "Session ", style: tui.style(fg: "dark_gray")),
          tui.span(content: "##{session[:id]}", style: tui.style(fg: "cyan", modifiers: [:bold]))
        ]),
        tui.line(spans: [
          tui.span(content: "Messages ", style: tui.style(fg: "dark_gray")),
          tui.span(content: session[:message_count].to_s, style: tui.style(fg: "cyan"))
        ]),
        tui.line(spans: [tui.span(content: "")]),
        tui.line(spans: [
          tui.span(content: "Mode ", style: tui.style(fg: "dark_gray")),
          tui.span(content: mode_label, style: tui.style(fg: mode_color, modifiers: [:bold]))
        ]),
        interaction_state_line(tui),
        tui.line(spans: [tui.span(content: "")]),
        connection_status_line(tui),
        tui.line(spans: [tui.span(content: "")]),
        tui.line(spans: [
          tui.span(content: "Ctrl+a", style: tui.style(fg: "cyan", modifiers: [:bold])),
          tui.span(content: " command mode", style: tui.style(fg: "dark_gray"))
        ])
      ]

      info = tui.paragraph(
        text: lines,
        block: tui.block(
          title: "Info",
          borders: [:all],
          border_type: :rounded,
          border_style: {fg: "white"}
        )
      )
      frame.render_widget(info, area)
    end

    # Builds the interaction state line for the info panel.
    # Shows "Thinking..." during LLM processing.
    def interaction_state_line(tui)
      if chat_loading?
        tui.line(spans: [
          tui.span(content: "Thinking...", style: tui.style(fg: "magenta", modifiers: [:bold]))
        ])
      else
        tui.line(spans: [tui.span(content: "")])
      end
    end

    # Builds the connection status line for the info panel.
    def connection_status_line(tui)
      cable_status = @cable_client.status

      if cable_status == :reconnecting
        attempt = @cable_client.reconnect_attempt
        max = CableClient::MAX_RECONNECT_ATTEMPTS
        label = "Reconnecting (#{attempt}/#{max})"
        color = "yellow"
      else
        style = STATUS_STYLES.fetch(cable_status, STATUS_STYLES[:disconnected])
        label = style[:label].strip
        color = style[:bg]
      end

      tui.line(spans: [
        tui.span(content: label, style: tui.style(fg: color, modifiers: [:bold]))
      ])
    end

    def chat_loading?
      @screens[:chat].loading?
    end

    def handle_event(event)
      return nil if event.none?
      return :quit if event.ctrl_c?

      if @command_mode
        handle_command_mode(event)
      else
        handle_normal_mode(event)
      end
    end

    def handle_command_mode(event)
      @command_mode = false

      return nil unless event.key?

      action = COMMAND_KEYS[event.code]
      case action
      when :quit
        :quit
      when :new_session
        @screens[:chat].new_session
        @current_screen = :chat
        nil
      when :view_mode
        @screens[:chat].cycle_view_mode
        @current_screen = :chat
        nil
      end
    end

    def handle_normal_mode(event)
      if event.mouse? || event.paste?
        delegate_to_screen(event)
        return nil
      end

      return nil unless event.key?

      if ctrl_a?(event)
        @command_mode = true
        return nil
      end

      delegate_to_screen(event)
      nil
    end

    # Forwards an event to the active screen for handling
    def delegate_to_screen(event)
      screen = @screens[@current_screen]
      screen.handle_event(event) if screen.respond_to?(:handle_event)
    end

    def ctrl_a?(event)
      event.code == "a" && event.modifiers&.include?("ctrl")
    end

    # Traps SIGHUP, SIGTERM, and SIGINT to trigger graceful shutdown.
    # Saves previous handlers so they can be restored when {#run} exits.
    # Must only be called once per {#run} invocation.
    # @return [void]
    def install_signal_handlers
      @previous_signal_handlers = {}
      SHUTDOWN_SIGNALS.each do |signal|
        @previous_signal_handlers[signal] = Signal.trap(signal) { @shutdown_requested = true }
      rescue ArgumentError
        # Signal not supported on this platform
      end
    end

    # Restores signal handlers that were in place before the TUI started.
    # @return [void]
    def restore_signal_handlers
      @previous_signal_handlers.each do |signal, handler|
        Signal.trap(signal, handler || "DEFAULT")
      rescue ArgumentError
        # Signal not restorable
      end
    end

    # Monitors the controlling terminal in a background thread.
    # RatatuiRuby's Rust layer (crossterm) intercepts SIGHUP at the native level,
    # preventing Ruby signal handlers from running when the PTY master closes
    # (tmux kill-session, SSH disconnect, terminal crash). This watchdog detects
    # terminal loss by probing {CONTROLLING_TERMINAL} and force-exits the process
    # since the main thread is stuck in native Rust code that cannot be interrupted.
    # @return [void]
    def start_terminal_watchdog
      @watchdog_thread = Thread.new { terminal_watchdog_loop }
    end

    # Stops the watchdog thread, waiting briefly for graceful exit before force-killing.
    # @return [void]
    def stop_terminal_watchdog
      return unless @watchdog_thread

      @watchdog_thread.join(WATCHDOG_SHUTDOWN_TIMEOUT)
      @watchdog_thread.kill if @watchdog_thread.alive?
      @watchdog_thread = nil
    end

    # Opens {CONTROLLING_TERMINAL} every {TERMINAL_CHECK_INTERVAL} seconds.
    # File.open (not File.stat) is required because stat only checks the
    # filesystem entry which always exists; open actually probes the device.
    # When the terminal disappears, calls {#handle_terminal_loss}.
    # Exits silently in non-TTY environments (CI, test suites).
    # @see CONTROLLING_TERMINAL
    # @see TERMINAL_CHECK_INTERVAL
    # @return [void]
    def terminal_watchdog_loop
      # Empty block triggers open syscall to probe the device, then immediately closes the FD.
      File.open(CONTROLLING_TERMINAL, "r") {}

      loop do
        break if @shutdown_requested
        begin
          File.open(CONTROLLING_TERMINAL, "r") {}
        rescue Errno::ENXIO, Errno::EIO, Errno::ENOENT
          handle_terminal_loss
        end
        sleep TERMINAL_CHECK_INTERVAL
      end
    rescue SystemCallError
      # No controlling terminal — nothing to watch (ENXIO, EIO, ENOENT, EACCES, etc.)
    end

    # Best-effort WebSocket cleanup followed by immediate process termination.
    # Uses Kernel.exit!(0) because the main thread is stuck in native Rust FFI
    # (crossterm poll_event/draw) and cannot be interrupted by Ruby signals.
    # @return [void]
    def handle_terminal_loss
      @cable_client.disconnect
    rescue
      nil
    ensure
      Kernel.exit!(0)
    end
  end
end
