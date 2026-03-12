# frozen_string_literal: true

require_relative "cable_client"
require_relative "message_store"
require_relative "screens/chat"
require_relative "screens/settings"
require_relative "screens/anthropic"

module TUI
  class App
    SCREENS = %i[chat settings anthropic].freeze

    COMMAND_KEYS = {
      "n" => :new_session,
      "s" => :settings,
      "a" => :anthropic,
      "q" => :quit
    }.freeze

    MENU_LABELS = COMMAND_KEYS.map { |key, action| "[#{key}] #{action.capitalize}" }.freeze

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
        chat: Screens::Chat.new(cable_client: cable_client),
        settings: Screens::Settings.new,
        anthropic: Screens::Anthropic.new
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
      main_area, sidebar = tui.split(
        frame.area,
        direction: :horizontal,
        constraints: [
          tui.constraint_fill(1),
          tui.constraint_length(SIDEBAR_WIDTH)
        ]
      )

      content_area, status_bar = tui.split(
        main_area,
        direction: :vertical,
        constraints: [
          tui.constraint_fill(1),
          tui.constraint_length(1)
        ]
      )

      @screens[@current_screen].render(frame, content_area, tui)
      render_sidebar(frame, sidebar, tui)
      render_status_bar(frame, status_bar, tui)
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

    def render_status_bar(frame, area, tui)
      mode_span = if @command_mode
        tui.span(content: " COMMAND ", style: tui.style(fg: "black", bg: "yellow", modifiers: [:bold]))
      elsif chat_loading?
        tui.span(content: " THINKING ", style: tui.style(fg: "black", bg: "magenta", modifiers: [:bold]))
      else
        tui.span(content: " NORMAL ", style: tui.style(fg: "black", bg: "cyan", modifiers: [:bold]))
      end

      conn_span = connection_status_span(tui)

      widget = tui.paragraph(text: tui.line(spans: [mode_span, conn_span]))
      frame.render_widget(widget, area)
    end

    def connection_status_span(tui)
      cable_status = @cable_client.status

      if cable_status == :reconnecting
        attempt = @cable_client.reconnect_attempt
        max = CableClient::MAX_RECONNECT_ATTEMPTS
        label = " RECONNECTING (#{attempt}/#{max}) "
        style = STATUS_STYLES[:reconnecting]
      else
        style = STATUS_STYLES.fetch(cable_status, STATUS_STYLES[:disconnected])
        label = style[:label]
      end

      tui.span(content: label, style: tui.style(fg: style[:fg], bg: style[:bg], modifiers: [:bold]))
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
      when :settings, :anthropic
        @current_screen = action
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

      if event.esc? && @current_screen != :chat
        @current_screen = :chat
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
    # @return [void]
    def terminal_watchdog_loop
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
    rescue Errno::ENXIO, Errno::EIO, Errno::ENOENT
      # No controlling terminal — nothing to watch
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
