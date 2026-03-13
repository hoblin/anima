# frozen_string_literal: true

require "time"
require_relative "cable_client"
require_relative "message_store"
require_relative "screens/chat"

module TUI
  class App
    SCREENS = %i[chat].freeze

    COMMAND_KEYS = {
      "n" => :new_session,
      "s" => :session_picker,
      "v" => :view_mode,
      "q" => :quit
    }.freeze

    MENU_LABELS = COMMAND_KEYS.map { |key, action| "[#{key}] #{action.to_s.tr("_", " ").capitalize}" }.freeze

    SIDEBAR_WIDTH = 28

    VIEW_MODE_LABELS = {
      "basic" => "Chat messages only",
      "verbose" => "Tools & timestamps",
      "debug" => "Full LLM context"
    }.freeze

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

    attr_reader :current_screen, :command_mode, :session_picker_active, :view_mode_picker_active
    # @return [Boolean] true when graceful shutdown has been requested via signal
    attr_reader :shutdown_requested

    # @param cable_client [TUI::CableClient] WebSocket client connected to the brain
    def initialize(cable_client:)
      @cable_client = cable_client
      @current_screen = :chat
      @command_mode = false
      @session_picker_active = false
      @session_picker_index = 0
      @view_mode_picker_active = false
      @view_mode_picker_index = 0
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
      if @session_picker_active
        render_session_picker(frame, area, tui)
      elsif @view_mode_picker_active
        render_view_mode_picker(frame, area, tui)
      elsif @command_mode
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

      if @session_picker_active
        handle_session_picker(event)
      elsif @view_mode_picker_active
        handle_view_mode_picker(event)
      elsif @command_mode
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
      when :session_picker
        activate_session_picker
        nil
      when :view_mode
        activate_view_mode_picker
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

    # -- Command mode pickers ------------------------------------------

    # Shared keyboard navigation for Command Mode picker overlays.
    # Handles arrow keys, Enter, Escape, and digit hotkeys.
    #
    # @param event [RatatuiRuby::Event] keyboard event
    # @param items [Array] list of selectable items
    # @param index_ivar [Symbol] instance variable name tracking selected index
    # @return [:close, Object, nil] :close on Escape, selected item on
    #   Enter/hotkey, nil otherwise
    def navigate_picker(event, items:, index_ivar:)
      return nil unless event.key?
      return :close if event.esc?

      current_index = instance_variable_get(index_ivar)

      if event.up?
        instance_variable_set(index_ivar, [current_index - 1, 0].max)
        return nil
      end

      if event.down?
        max = [items.size - 1, 0].max
        instance_variable_set(index_ivar, [current_index + 1, max].min)
        return nil
      end

      if event.enter? && items.any?
        return items[current_index]
      end

      idx = hotkey_to_index(event.code)
      if idx && idx < items.size
        return items[idx]
      end

      nil
    end

    # Maps digit key codes to picker list indices.
    # Keys 1-9 map to indices 0-8, key 0 maps to index 9.
    #
    # @param code [String] the key code
    # @return [Integer, nil] list index, or nil for non-digit keys
    def hotkey_to_index(code)
      return nil unless code.length == 1

      case code
      when "1".."9" then code.to_i - 1
      when "0" then 9
      end
    end

    # Returns the hotkey character for a given picker list position.
    # Positions 0-8 get keys "1"-"9", position 9 gets "0".
    #
    # @param idx [Integer] zero-based list position
    # @return [String, nil] hotkey character, or nil for positions beyond 9
    def picker_hotkey(idx)
      return (idx + 1).to_s if idx < 9
      return "0" if idx == 9
      nil
    end

    # -- Session picker ------------------------------------------------

    # Requests the session list from the brain and opens the picker overlay.
    # @return [void]
    def activate_session_picker
      @session_picker_active = true
      @session_picker_index = 0
      @cable_client.list_sessions
    end

    # Dispatches keyboard events while the session picker overlay is open.
    #
    # @param event [RatatuiRuby::Event] keyboard event
    # @return [nil]
    def handle_session_picker(event)
      sessions = @screens[:chat].sessions_list || []
      result = navigate_picker(event, items: sessions, index_ivar: :@session_picker_index)

      case result
      when :close
        @session_picker_active = false
      when Hash
        pick_session(result)
      end

      nil
    end

    # Switches to the selected session and closes the picker.
    #
    # @param session [Hash] session entry from sessions_list
    # @return [void]
    def pick_session(session)
      return unless session

      @session_picker_active = false
      @screens[:chat].switch_session(session["id"])
    end

    # Renders the session picker overlay in the sidebar.
    # Shows a loading indicator until the sessions_list arrives from the brain.
    #
    # @param frame [RatatuiRuby::Frame] terminal frame for widget rendering
    # @param area [RatatuiRuby::Rect] sidebar area to render into
    # @param tui [RatatuiRuby] TUI rendering API
    # @return [void]
    def render_session_picker(frame, area, tui)
      sessions = @screens[:chat].sessions_list
      current_id = @screens[:chat].session_info[:id]

      if sessions.nil?
        lines = [tui.line(spans: [
          tui.span(content: "Loading...", style: tui.style(fg: "yellow"))
        ])]
      else
        lines = sessions.each_with_index.flat_map do |session, idx|
          format_session_picker_entry(tui, session, idx, current_id)
        end

        if lines.empty?
          lines = [tui.line(spans: [
            tui.span(content: "No sessions", style: tui.style(fg: "dark_gray"))
          ])]
        end
      end

      picker = tui.paragraph(
        text: lines,
        block: tui.block(
          title: "Sessions",
          borders: [:all],
          border_type: :rounded,
          border_style: {fg: "cyan"}
        )
      )
      frame.render_widget(picker, area)
    end

    # Formats a single session entry for the picker. Highlights the selected
    # entry and marks the currently active session.
    #
    # @param tui [RatatuiRuby] TUI rendering API
    # @param session [Hash] session data with "id", "message_count", "updated_at"
    # @param idx [Integer] position in the list (determines hotkey)
    # @param current_id [Integer] the active session's ID
    # @return [Array<RatatuiRuby::Widgets::Line>] single line for this entry
    def format_session_picker_entry(tui, session, idx, current_id)
      selected = idx == @session_picker_index
      is_current = session["id"] == current_id

      hotkey = picker_hotkey(idx)
      prefix = hotkey ? "[#{hotkey}]" : "   "
      marker = is_current ? "*" : " "
      id_label = "##{session["id"]}"
      count = "#{session["message_count"]}msg"
      time = format_relative_time(session["updated_at"])

      label = "#{prefix}#{marker}#{id_label} #{count} #{time}"

      style = if selected
        tui.style(fg: "black", bg: "cyan")
      elsif is_current
        tui.style(fg: "cyan", modifiers: [:bold])
      else
        tui.style(fg: "white")
      end

      [tui.line(spans: [tui.span(content: label, style: style)])]
    end

    # -- View mode picker ----------------------------------------------

    # Opens the view mode picker overlay. Pre-selects the current mode.
    # @return [void]
    def activate_view_mode_picker
      @view_mode_picker_active = true
      @view_mode_picker_index = Screens::Chat::VIEW_MODES.index(@screens[:chat].view_mode) || 0
    end

    # Dispatches keyboard events while the view mode picker is open.
    #
    # @param event [RatatuiRuby::Event] keyboard event
    # @return [nil]
    def handle_view_mode_picker(event)
      result = navigate_picker(event, items: Screens::Chat::VIEW_MODES, index_ivar: :@view_mode_picker_index)

      case result
      when :close
        @view_mode_picker_active = false
      when String
        pick_view_mode(result)
      end

      nil
    end

    # Switches to the selected view mode and closes the picker.
    #
    # @param mode [String] view mode name
    # @return [void]
    def pick_view_mode(mode)
      @view_mode_picker_active = false
      @screens[:chat].switch_view_mode(mode)
    end

    # Renders the view mode picker overlay in the sidebar.
    #
    # @param frame [RatatuiRuby::Frame] terminal frame for widget rendering
    # @param area [RatatuiRuby::Rect] sidebar area to render into
    # @param tui [RatatuiRuby] TUI rendering API
    # @return [void]
    def render_view_mode_picker(frame, area, tui)
      current_mode = @screens[:chat].view_mode

      lines = Screens::Chat::VIEW_MODES.each_with_index.flat_map do |mode, idx|
        format_view_mode_entry(tui, mode, idx, current_mode)
      end

      picker = tui.paragraph(
        text: lines,
        block: tui.block(
          title: "View Mode",
          borders: [:all],
          border_type: :rounded,
          border_style: {fg: "cyan"}
        )
      )
      frame.render_widget(picker, area)
    end

    # Formats a view mode entry with name and description.
    # Highlights the selected entry and marks the current mode.
    #
    # @param tui [RatatuiRuby] TUI rendering API
    # @param mode [String] view mode name
    # @param idx [Integer] position in the list
    # @param current_mode [String] currently active mode
    # @return [Array<RatatuiRuby::Widgets::Line>] name and description lines
    def format_view_mode_entry(tui, mode, idx, current_mode)
      selected = idx == @view_mode_picker_index
      is_current = mode == current_mode

      hotkey = picker_hotkey(idx)
      prefix = hotkey ? "[#{hotkey}]" : "   "
      marker = is_current ? "*" : " "

      selected_style = tui.style(fg: "black", bg: "cyan")

      name_style = if selected
        selected_style
      elsif is_current
        tui.style(fg: "cyan", modifiers: [:bold])
      else
        tui.style(fg: "white")
      end

      desc_style = selected ? selected_style : tui.style(fg: "dark_gray")

      [
        tui.line(spans: [tui.span(content: "#{prefix}#{marker}#{mode.capitalize}", style: name_style)]),
        tui.line(spans: [tui.span(content: "     #{VIEW_MODE_LABELS[mode]}", style: desc_style)])
      ]
    end

    # Formats an ISO8601 timestamp as a human-readable relative time.
    #
    # @param iso_string [String, nil] ISO8601 timestamp
    # @return [String] e.g. "2m ago", "3h ago", "Mar 12"
    def format_relative_time(iso_string)
      return "" unless iso_string

      time = Time.parse(iso_string)
      delta = Time.now - time

      if delta < 60
        "now"
      elsif delta < 3_600
        "#{(delta / 60).to_i}m ago"
      elsif delta < 86_400
        "#{(delta / 3_600).to_i}h ago"
      else
        time.strftime("%b %d")
      end
    rescue ArgumentError
      ""
    end

    # -- Signal handling -----------------------------------------------

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
