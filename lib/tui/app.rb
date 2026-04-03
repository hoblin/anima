# frozen_string_literal: true

require "time"
require_relative "settings"
require_relative "cable_client"
require_relative "input_buffer"
require_relative "message_store"
require_relative "performance_logger"
require_relative "screens/chat"

module TUI
  class App
    SCREENS = %i[chat].freeze

    COMMAND_KEYS = {
      "a" => :anthropic_token,
      "h" => :toggle_hud,
      "n" => :new_session,
      "s" => :session_picker,
      "v" => :view_mode,
      "q" => :quit
    }.freeze

    MENU_LABELS = (COMMAND_KEYS.map { |key, action| "[#{key}] #{action.to_s.tr("_", " ").capitalize}" } +
      ["[\u2191] Scroll chat", "[\u2193] Return to input", "[\u2192] Scroll HUD"]).freeze

    # Picker entry prefix width: "[N]" (3) + marker (1) + space (1) = 5
    PICKER_PREFIX_WIDTH = 5

    # User-facing descriptions shown below each mode name in the view mode picker.
    VIEW_MODE_LABELS = {
      "basic" => "Chat messages only",
      "verbose" => "Tools & timestamps",
      "debug" => "Full LLM context"
    }.freeze

    # Connection status emoji indicators for the info panel.
    # Subscribed (normal state) shows only the emoji; other states add text.
    STATUS_STYLES = {
      disconnected: {label: "🔴 Disconnected", color: "red"},
      connecting: {label: "🟡 Connecting", color: "yellow"},
      connected: {label: "🟡 Connecting", color: "yellow"},
      subscribed: {label: "🟢", color: "green"},
      reconnecting: {label: "🟡 Reconnecting", color: "yellow"}
    }.freeze

    # Matches a single printable Unicode character (no control codes).
    PRINTABLE_CHAR = /\A[[:print:]]\z/

    # Signals that trigger graceful shutdown when received from the OS.
    SHUTDOWN_SIGNALS = %w[HUP TERM INT].freeze

    # Unix controlling terminal device path.
    # @see #terminal_watchdog_loop
    CONTROLLING_TERMINAL = "/dev/tty"

    attr_reader :current_screen, :command_mode, :session_picker_active,
      :view_mode_picker_active
    # @return [Boolean] true when the HUD info panel is visible
    attr_reader :hud_visible
    # @return [Boolean] true when the HUD pane has keyboard focus for scrolling
    attr_reader :hud_focused
    # @return [Boolean] true when the token setup popup overlay is visible
    attr_reader :token_setup_active
    # @return [Boolean] true when graceful shutdown has been requested via signal
    attr_reader :shutdown_requested
    # @return [TUI::PerformanceLogger] frame timing logger (no-op when debug is off)
    attr_reader :perf_logger

    # @param cable_client [TUI::CableClient] WebSocket client connected to the brain
    # @param debug [Boolean] enable performance logging to log/tui_performance.log
    def initialize(cable_client:, debug: false)
      @cable_client = cable_client
      @perf_logger = PerformanceLogger.new(enabled: debug)
      @current_screen = :chat
      @command_mode = false
      @session_picker_active = false
      @session_picker_index = 0
      @session_picker_page = 0
      @session_picker_mode = :root
      @session_picker_parent_id = nil
      @hud_visible = true
      @hud_focused = false
      @hud_scroll_offset = 0
      @hud_max_scroll = 0
      @hud_visible_height = 0
      @hud_content_area = nil
      @view_mode_picker_active = false
      @view_mode_picker_index = 0
      @token_setup_active = false
      @token_input_buffer = InputBuffer.new
      @token_setup_error = nil
      @token_setup_warning = nil
      @token_setup_status = :idle
      @shutdown_requested = false
      @previous_signal_handlers = {}
      @watchdog_thread = nil
      @screens = {
        chat: Screens::Chat.new(cable_client: cable_client, perf_logger: @perf_logger)
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
      @perf_logger.start_frame

      @screens[:chat].hud_hint = !@hud_visible

      if @hud_visible
        hud_width = [frame.area.width / 3, Settings.hud_min_width].max
        content_area, sidebar = tui.split(
          frame.area,
          direction: :horizontal,
          constraints: [
            tui.constraint_fill(1),
            tui.constraint_length(hud_width)
          ]
        )

        @perf_logger.measure(:chat_render) { @screens[@current_screen].render(frame, content_area, tui) }
        @perf_logger.measure(:sidebar) { render_sidebar(frame, sidebar, tui) }
      else
        @perf_logger.measure(:chat_render) { @screens[@current_screen].render(frame, frame.area, tui) }
      end

      check_token_setup_signals
      render_token_setup_popup(frame, frame.area, tui) if @token_setup_active

      @perf_logger.end_frame
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

    # HUD status icons for goal progress and sub-agent activity.
    GOAL_ICON_ACTIVE = "\u25CF"       # ●
    GOAL_ICON_IN_PROGRESS = "\u25D0"  # ◐
    GOAL_ICON_COMPLETED = "\u2713"    # ✓

    # Sub-agent state icons — form communicates type of work,
    # color communicates status. Work independently.
    CHILD_ICON_IDLE = "\u25CC"              # ◌ hollow — nothing happening
    CHILD_ICON_GENERATING = "\u25CF"        # ● filled — LLM thinking
    CHILD_ICON_TOOL_EXECUTING = "\u25C9"    # ◉ dot-in-circle — tool running
    CHILD_ICON_INTERRUPTING = "\u25CF"      # ● filled — stopping

    def render_info(frame, area, tui)
      session = @screens[:chat].session_info
      stats = @screens[:chat].message_store.token_economy
      has_metrics = stats[:call_count] > 0 || stats[:rate_limits]

      # Split into main content, optional token economy panel, and status bar
      if has_metrics
        economy_height = token_economy_line_count(stats) + 1 # +1 for top border
        main_area, economy_area, status_area = tui.split(
          area,
          direction: :vertical,
          constraints: [
            tui.constraint_fill(1),
            tui.constraint_length(economy_height),
            tui.constraint_length(2)
          ]
        )
        render_hud_content(frame, main_area, tui, session)
        render_token_economy_panel(frame, economy_area, tui, stats)
      else
        main_area, status_area = tui.split(
          area,
          direction: :vertical,
          constraints: [
            tui.constraint_fill(1),
            tui.constraint_length(2)
          ]
        )
        render_hud_content(frame, main_area, tui, session)
      end
      render_hud_status_bar(frame, status_area, tui)
    end

    # Renders the main HUD content: session name, goals, skills,
    # workflow, and sub-agents. Supports vertical scrolling with
    # a scrollbar when content exceeds the visible area.
    def render_hud_content(frame, area, tui, session)
      @hud_content_area = area
      session_label = session[:name] || "##{session[:id]}"

      lines = [
        tui.line(spans: [
          tui.span(content: "\u{1F4CB} ", style: tui.style(fg: "dark_gray")),
          tui.span(content: session_label, style: tui.style(fg: "cyan", modifiers: [:bold]))
        ]),
        hud_goals_section(tui, session),
        hud_skills_line(tui, session),
        hud_workflow_line(tui, session),
        hud_children_section(tui, session),
        interaction_state_line(tui)
      ].flatten.compact

      @hud_visible_height = [area.height - 2, 0].max
      inner_width = [area.width - 2, 1].max
      total_height = tui.paragraph(text: lines, wrap: true).line_count(inner_width)
      @hud_max_scroll = [total_height - @hud_visible_height, 0].max
      @hud_scroll_offset = @hud_scroll_offset.clamp(0, @hud_max_scroll)

      border_color = @hud_focused ? Settings.border_focused : Settings.border_normal

      content = tui.paragraph(
        text: lines,
        wrap: true,
        scroll: [@hud_scroll_offset, 0],
        block: tui.block(
          borders: [:left, :top, :right],
          border_type: :rounded,
          border_style: {fg: border_color}
        )
      )
      frame.render_widget(content, area)

      render_hud_scrollbar(frame, area, tui)
    end

    # Renders a scrollbar on the right edge of the HUD when content overflows.
    def render_hud_scrollbar(frame, area, tui)
      return unless @hud_max_scroll > 0

      scrollbar = tui.scrollbar(
        content_length: @hud_max_scroll,
        position: @hud_scroll_offset,
        orientation: :vertical_right,
        thumb_style: {fg: Settings.scrollbar_thumb},
        track_symbol: "\u2502",
        track_style: {fg: Settings.scrollbar_track}
      )
      frame.render_widget(scrollbar, area)
    end

    # Renders the bottom status bar: connection state and model name.
    def render_hud_status_bar(frame, area, tui)
      cable_status = @cable_client.status
      style = STATUS_STYLES.fetch(cable_status, STATUS_STYLES[:disconnected])

      status_label = if cable_status == :reconnecting
        attempt = @cable_client.reconnect_attempt
        max = Settings.max_reconnect_attempts
        "#{style[:label]} (#{attempt}/#{max})"
      else
        style[:label]
      end

      view_mode = @screens[:chat].view_mode
      mode_label = view_mode.capitalize
      mode_color = case view_mode
      when "verbose" then "yellow"
      when "debug" then "magenta"
      else "cyan"
      end

      bar = tui.paragraph(
        text: [
          tui.line(spans: [
            tui.span(content: "  ", style: tui.style(fg: "dark_gray")),
            tui.span(content: status_label, style: tui.style(fg: style[:color], modifiers: [:bold])),
            tui.span(content: " ", style: tui.style(fg: "dark_gray")),
            tui.span(content: mode_label, style: tui.style(fg: mode_color, modifiers: [:bold]))
          ])
        ],
        block: tui.block(
          borders: [:left, :bottom, :right],
          border_type: :rounded,
          border_style: {fg: "white"}
        )
      )
      frame.render_widget(bar, area)
    end

    # Builds goal lines with status icons and descriptions.
    # Root goals show as individual lines. A root goal with some completed
    # sub-goals shows the ◐ (in-progress) icon.
    #
    # @return [Array<RatatuiRuby::Widgets::Line>, nil]
    def hud_goals_section(tui, session)
      goal_list = session[:goals]
      return if goal_list.nil? || goal_list.empty?

      lines = [
        tui.line(spans: [tui.span(content: "")]),
        tui.line(spans: [
          tui.span(content: "\u{1F3AF} Goals", style: tui.style(fg: "dark_gray"))
        ])
      ]

      goal_list.each do |goal|
        icon, color = goal_icon_and_color(goal)
        lines << tui.line(spans: [
          tui.span(content: "  #{icon} ", style: tui.style(fg: color)),
          tui.span(content: goal["description"].to_s, style: tui.style(fg: "white"))
        ])
      end

      lines
    end

    # Returns the status icon and color for a goal.
    # Active goals with some completed sub-goals show as in-progress (◐).
    #
    # @param goal [Hash] goal data with "status" and optional "sub_goals" keys
    # @return [Array(String, String)] icon and color pair
    def goal_icon_and_color(goal)
      if goal["status"] == "completed"
        [GOAL_ICON_COMPLETED, "green"]
      elsif goal["sub_goals"]&.any? { |sg| sg["status"] == "completed" }
        [GOAL_ICON_IN_PROGRESS, "yellow"]
      else
        [GOAL_ICON_ACTIVE, "cyan"]
      end
    end

    # Builds the skills line with brain emoji.
    # @return [Array<RatatuiRuby::Widgets::Line>, nil]
    def hud_skills_line(tui, session)
      skills = session[:active_skills]
      return if skills.nil? || skills.empty?

      [
        tui.line(spans: [tui.span(content: "")]),
        tui.line(spans: [
          tui.span(content: "\u{1F9E0} ", style: tui.style(fg: "dark_gray")),
          tui.span(content: skills.join(", "), style: tui.style(fg: "yellow"))
        ])
      ]
    end

    # Builds the workflow line with scroll emoji.
    # @return [Array<RatatuiRuby::Widgets::Line>, nil]
    def hud_workflow_line(tui, session)
      workflow = session[:active_workflow]
      return if workflow.nil? || workflow.empty?

      [
        tui.line(spans: [tui.span(content: "")]),
        tui.line(spans: [
          tui.span(content: "\u{1F4DC} ", style: tui.style(fg: "dark_gray")),
          tui.span(content: workflow, style: tui.style(fg: "magenta"))
        ])
      ]
    end

    # Builds the sub-agents section with activity indicators.
    # @return [Array<RatatuiRuby::Widgets::Line>, nil]
    def hud_children_section(tui, session)
      children = session[:children]
      return if children.nil? || children.empty?

      lines = [
        tui.line(spans: [tui.span(content: "")]),
        tui.line(spans: [
          tui.span(content: "\u{1F465} Sub-agents", style: tui.style(fg: "dark_gray"))
        ])
      ]

      children.each do |child|
        icon, color = child_icon_and_color(child)
        name = child["name"] || "sub-agent"
        lines << tui.line(spans: [
          tui.span(content: "  #{icon} ", style: tui.style(fg: color)),
          tui.span(content: "@#{name}", style: tui.style(fg: "white"))
        ])
      end

      lines
    end

    # Returns the activity icon and color for a child session.
    # Form communicates type of work, color communicates status —
    # they work independently so even without color the shape tells
    # the story.
    #
    # @param child [Hash] child session data with "session_state" key
    # @return [Array(String, String)] icon and color pair
    def child_icon_and_color(child)
      case child["session_state"]
      when "llm_generating"
        [CHILD_ICON_GENERATING, "green"]
      when "tool_executing"
        [CHILD_ICON_TOOL_EXECUTING, "green"]
      when "interrupting"
        [CHILD_ICON_INTERRUPTING, "red"]
      else
        [CHILD_ICON_IDLE, "dark_gray"]
      end
    end

    # Renders the Token Economy panel as a fixed section between HUD content
    # and the status bar.
    def render_token_economy_panel(frame, area, tui, stats)
      lines = []

      rate_limits = stats[:rate_limits]
      lines.concat(build_rate_limit_lines(tui, rate_limits)) if rate_limits
      lines.concat(build_cache_metrics_lines(tui, stats)) if stats[:call_count] > 0

      panel = tui.paragraph(
        text: lines,
        block: tui.block(
          title: " \u{1F4CA} Token Economy ",
          borders: [:left, :top, :right],
          border_type: :rounded,
          border_style: {fg: "white"}
        )
      )
      frame.render_widget(panel, area)
    end

    # Returns the number of content lines the token economy panel will render.
    def token_economy_line_count(stats)
      count = 0
      if stats[:rate_limits]
        count += 1 if stats[:rate_limits]["5h_utilization"]
        count += 1 if stats[:rate_limits]["7d_utilization"]
      end
      if stats[:call_count] > 0
        count += 2 # cache hit bar + saved
        count += 1 if stats[:cache_history]&.size.to_i > 1 # sparkline
      end
      count
    end

    # Builds rate limit display lines with progress bars and pacing.
    # Compact aligned labels: 5h, 7d (same 2-char width).
    # @return [Array<RatatuiRuby::Widgets::Line>]
    def build_rate_limit_lines(tui, rate_limits)
      lines = []

      # 5-hour window
      util_5h = rate_limits["5h_utilization"]
      if util_5h
        pct = (util_5h * 100).round
        bar = build_progress_bar(pct, Settings.progress_bar_width)
        color = rate_limit_color(pct)
        reset_5h = rate_limits["5h_reset"]
        reset_label = reset_5h ? " #{format_reset_time(reset_5h)}" : ""

        lines << tui.line(spans: [
          tui.span(content: "  5h ", style: tui.style(fg: color, modifiers: [:bold])),
          tui.span(content: bar, style: tui.style(fg: color)),
          tui.span(content: " #{pct.to_s.rjust(2)}%", style: tui.style(fg: color)),
          tui.span(content: reset_label, style: tui.style(fg: "dark_gray"))
        ])
      end

      # 7-day window
      util_7d = rate_limits["7d_utilization"]
      if util_7d
        pct = (util_7d * 100).round
        bar = build_progress_bar(pct, Settings.progress_bar_width)
        color = rate_limit_color(pct)

        lines << tui.line(spans: [
          tui.span(content: "  7d ", style: tui.style(fg: color, modifiers: [:bold])),
          tui.span(content: bar, style: tui.style(fg: color)),
          tui.span(content: " #{pct.to_s.rjust(2)}%", style: tui.style(fg: color))
        ])
      end

      lines
    end

    # Builds cache efficiency display lines with sparkline graph.
    # ⚡ for hit rate bar, braille sparkline for per-call history, 💾 for saved.
    # @return [Array<RatatuiRuby::Widgets::Line>]
    def build_cache_metrics_lines(tui, stats)
      hit_rate = (stats[:cache_hit_rate] * 100).round
      color = cache_hit_color(hit_rate)
      bar = build_progress_bar(hit_rate, Settings.progress_bar_width)

      total_cached = stats[:cache_read_input_tokens]
      saved_label = format_token_count(total_cached)

      lines = [
        tui.line(spans: [
          tui.span(content: "  \u{26A1} ", style: tui.style(fg: color)),
          tui.span(content: bar, style: tui.style(fg: color)),
          tui.span(content: " #{hit_rate.to_s.rjust(2)}%", style: tui.style(fg: color))
        ]),
        tui.line(spans: [
          tui.span(content: "  \u{1F4BE} ", style: tui.style(fg: "green")),
          tui.span(content: saved_label, style: tui.style(fg: "green"))
        ])
      ]

      # Braille sparkline: per-call cache hit history (below icons)
      history = stats[:cache_history]
      if history && history.size > 1
        sparkline = build_braille_sparkline(history)
        color = cache_hit_color(hit_rate)
        lines << tui.line(spans: [
          tui.span(content: "     ", style: tui.style(fg: "dark_gray")),
          tui.span(content: sparkline, style: tui.style(fg: color))
        ])
      end

      lines
    end

    # Builds a braille sparkline from a series of values (0.0-1.0).
    # Each braille character encodes two adjacent data points using
    # the left and right dot columns (4 dots each = 5 levels: 0-4).
    #
    # @param values [Array<Float>] data points between 0.0 and 1.0
    # @return [String] braille sparkline string
    def build_braille_sparkline(values)
      # Braille dot positions: left column (dots 1,2,3,7), right column (dots 4,5,6,8)
      # Numbered per Unicode spec: bit 0=dot1, bit 1=dot2, bit 2=dot3,
      # bit 3=dot4, bit 4=dot5, bit 5=dot6, bit 6=dot7, bit 7=dot8
      left_dots = [0x01, 0x02, 0x04, 0x40]   # dots 1,2,3,7 (bottom to top)
      right_dots = [0x08, 0x10, 0x20, 0x80]   # dots 4,5,6,8 (bottom to top)

      chars = []
      values.each_slice(2) do |pair|
        code = 0x2800 # braille base
        # Left column: first value
        fill_left = (pair[0].clamp(0.0, 1.0) * 4).round
        fill_left.times { |i| code |= left_dots[i] }
        # Right column: second value (or repeat first if odd)
        right_val = pair[1] || pair[0]
        fill_right = (right_val.clamp(0.0, 1.0) * 4).round
        fill_right.times { |i| code |= right_dots[i] }
        chars << code.chr(Encoding::UTF_8)
      end
      chars.join
    end

    # Builds a Unicode progress bar.
    # @param pct [Integer] percentage (0-100)
    # @param width [Integer] bar width in characters
    # @return [String] progress bar string
    def build_progress_bar(pct, width)
      filled = (pct.clamp(0, 100) * width / 100.0).round
      empty = width - filled
      ("\u2593" * filled) + ("\u2591" * empty)
    end

    # Color for rate limit percentage: green below warning, yellow below critical, red above.
    def rate_limit_color(pct)
      return "red" if pct >= Settings.rate_limit_critical
      return "yellow" if pct >= Settings.rate_limit_warning
      "green"
    end

    # Color for cache hit rate: green above good, yellow above low, red below.
    def cache_hit_color(pct)
      return "green" if pct >= Settings.cache_hit_good
      return "yellow" if pct >= Settings.cache_hit_low
      "red"
    end

    # Formats a reset timestamp as time remaining (e.g., "2h15m").
    def format_reset_time(epoch_seconds)
      diff = epoch_seconds - Time.now.to_i
      return "soon" if diff <= 0

      hours = diff / 3600
      minutes = (diff % 3600) / 60
      if hours > 0
        "\u279E#{hours}h#{minutes.to_s.rjust(2, "0")}m"
      else
        "\u279E#{minutes}m"
      end
    end

    # Formats a token count for display (e.g., "47.2K").
    def format_token_count(count)
      return "0" if count == 0
      return count.to_s if count < 1000
      "#{(count / 1000.0).round(1)}K tokens"
    end

    # Shows focus mode when a pane is focused, or the braille spinner
    # during active processing.
    def interaction_state_line(tui)
      if @hud_focused
        tui.line(spans: [
          tui.span(content: "HUD Scroll", style: tui.style(fg: "yellow", modifiers: [:bold]))
        ])
      elsif @screens[:chat].chat_focused
        tui.line(spans: [
          tui.span(content: "Scrolling", style: tui.style(fg: "yellow", modifiers: [:bold]))
        ])
      elsif chat_loading?
        chat = @screens[:chat]
        char = chat.spinner.tick || "\u2800"
        color = chat.spinner_color
        label = chat.spinner_label
        tui.line(spans: [
          tui.span(content: "#{char} ", style: tui.style(fg: color, modifiers: [:bold])),
          tui.span(content: label, style: tui.style(fg: color))
        ])
      end
    end

    def chat_loading?
      @screens[:chat].loading?
    end

    # Switches keyboard focus to the HUD pane for scrolling.
    # Unfocuses the chat pane if it was focused.
    #
    # @return [void]
    def focus_hud
      @screens[:chat].unfocus_chat if @screens[:chat].chat_focused
      @hud_focused = true
    end

    # Returns keyboard focus from the HUD pane.
    #
    # @return [void]
    def unfocus_hud
      @hud_focused = false
    end

    # Scrolls the HUD viewport up, clamping at the top.
    #
    # @param lines [Integer] number of lines to scroll
    # @return [void]
    def scroll_hud_up(lines)
      @hud_scroll_offset = [@hud_scroll_offset - lines, 0].max
    end

    # Scrolls the HUD viewport down, clamping at max_scroll.
    #
    # @param lines [Integer] number of lines to scroll
    # @return [void]
    def scroll_hud_down(lines)
      @hud_scroll_offset = [@hud_scroll_offset + lines, @hud_max_scroll].min
    end

    def handle_event(event)
      return nil if event.none?
      return :quit if event.ctrl_c?

      if @token_setup_active
        handle_token_setup(event)
      elsif @session_picker_active
        handle_session_picker(event)
      elsif @view_mode_picker_active
        handle_view_mode_picker(event)
      elsif @command_mode
        handle_command_mode(event)
      elsif @hud_focused
        handle_hud_focused_event(event)
      else
        handle_normal_mode(event)
      end
    end

    def handle_command_mode(event)
      @command_mode = false

      return nil unless event.key?

      if event.up?
        @screens[:chat].focus_chat
        return nil
      end

      if event.down?
        @screens[:chat].unfocus_chat
        return nil
      end

      if event.right? && @hud_visible
        focus_hud
        return nil
      end

      action = COMMAND_KEYS[event.code]
      case action
      when :quit
        :quit
      when :anthropic_token
        activate_token_setup
        nil
      when :toggle_hud
        @hud_visible = !@hud_visible
        unfocus_hud if !@hud_visible
        nil
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
      if event.paste?
        delegate_to_screen(event)
        return nil
      end

      if event.mouse?
        return nil if route_mouse_to_hud(event)
        delegate_to_screen(event)
        return nil
      end

      return nil unless event.key?

      if ctrl_a?(event)
        @command_mode = true
        return nil
      end

      # Escape key priority: unfocus chat > interrupt tools > clear input > parent session
      if event.esc?
        chat = @screens[:chat]
        if chat.chat_focused
          chat.unfocus_chat
        elsif chat.loading? && chat.input.empty?
          chat.interrupt_execution
        elsif !chat.input.empty?
          chat.clear_input
        else
          return_to_parent_session
        end
        return nil
      end

      delegate_to_screen(event)
      nil
    end

    # Handles keyboard events when the HUD pane has focus.
    # Arrow keys and Page Up/Down scroll the HUD; Escape and Ctrl+A exit.
    def handle_hud_focused_event(event)
      return nil if event.none?
      return :quit if event.ctrl_c?

      if event.mouse?
        return nil if route_mouse_to_hud(event)
        delegate_to_screen(event)
        return nil
      end

      return nil unless event.key?

      if event.esc? || ctrl_a?(event)
        unfocus_hud
        return nil
      end

      if event.up?
        scroll_hud_up(Settings.hud_scroll_step)
      elsif event.down?
        scroll_hud_down(Settings.hud_scroll_step)
      elsif event.page_up?
        scroll_hud_up(@hud_visible_height)
      elsif event.page_down?
        scroll_hud_down(@hud_visible_height)
      elsif event.home?
        scroll_hud_up(@hud_max_scroll)
      elsif event.end?
        scroll_hud_down(@hud_max_scroll)
      end
      nil
    end

    # Routes mouse scroll events to the HUD when the cursor is over the HUD area.
    # @return [Boolean] true if the event was handled by the HUD
    def route_mouse_to_hud(event)
      return false if !@hud_visible || !@hud_content_area
      return false unless mouse_over_hud?(event)
      return false unless event.scroll_up? || event.scroll_down?

      if event.scroll_up?
        scroll_hud_up(Settings.hud_mouse_scroll_step)
      else
        scroll_hud_down(Settings.hud_mouse_scroll_step)
      end
      true
    end

    # Checks whether a mouse event's coordinates fall within the HUD content area.
    def mouse_over_hud?(event)
      area = @hud_content_area
      event.x >= area.x && event.x < area.x + area.width &&
        event.y >= area.y && event.y < area.y + area.height
    end

    # Switches to the parent session when viewing a child (sub-agent) session.
    # No-op if the current session is a root session.
    #
    # @return [void]
    def return_to_parent_session
      parent_id = @screens[:chat].parent_session_id
      return unless parent_id

      @screens[:chat].switch_session(parent_id)
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
    # Keys 1-9 map to indices 0-8. Key 0 is reserved for Load More in paginated pickers.
    #
    # @param code [String] the key code
    # @return [Integer, nil] list index, or nil for non-digit keys
    def hotkey_to_index(code)
      return nil unless code.length == 1

      code.to_i - 1 if ("1".."9").cover?(code)
    end

    # Returns the hotkey character for a given picker list position.
    # Positions 0-8 get keys "1"-"9". Positions beyond 8 get no hotkey.
    #
    # @param idx [Integer] zero-based list position
    # @return [String, nil] hotkey character, or nil for positions beyond 8
    def picker_hotkey(idx)
      (idx + 1).to_s if idx >= 0 && idx < 9
    end

    # -- Session picker ------------------------------------------------

    # Status indicators for child session state.
    CHILD_STATUS_RUNNING = "\u27F3"   # ⟳
    CHILD_STATUS_DONE = "\u2713"      # ✓
    CHILDREN_ARROW = "\u25B8"         # ▸ shown next to sessions with children
    UNNAMED_SUBAGENT_LABEL = "sub-agent"
    BACK_ARROW = "\u2190"             # ←

    # Requests the session list from the brain and opens the picker overlay.
    # Fetches up to Settings.session_picker_fetch_limit sessions for client-side pagination.
    # @return [void]
    def activate_session_picker
      @session_picker_active = true
      @session_picker_index = 0
      @session_picker_page = 0
      @session_picker_mode = :root
      @session_picker_parent_id = nil
      @cable_client.list_sessions(limit: Settings.session_picker_fetch_limit)
    end

    # Dispatches keyboard events while the session picker overlay is open.
    # Supports drill-down navigation: root sessions → children, with
    # pagination via key 0 (Load More) at both levels.
    #
    # @param event [RatatuiRuby::Event] keyboard event
    # @return [nil]
    def handle_session_picker(event)
      return nil unless event.key?

      if event.esc?
        handle_session_picker_escape
        return nil
      end

      visible = session_picker_visible_items
      return nil if visible.empty?

      if event.up?
        @session_picker_index = [@session_picker_index - 1, 0].max
      elsif event.down?
        @session_picker_index = [@session_picker_index + 1, visible.size - 1].min
      elsif event.right?
        drill_into_children(visible)
      elsif event.left?
        return_to_root_sessions
      elsif event.enter?
        select_session_picker_item(visible)
      elsif event.code == "0" && session_picker_has_more?
        load_more_sessions
      else
        idx = hotkey_to_index(event.code)
        if idx && idx < visible.size
          @session_picker_index = idx
          select_session_picker_item(visible)
        end
      end

      nil
    end

    # Returns the raw items for the current picker mode (root sessions or children).
    #
    # @return [Array<Hash>] session or child hashes from the sessions list
    def session_picker_all_items_for_mode
      sessions = @screens[:chat].sessions_list || []

      case @session_picker_mode
      when :root
        sessions
      when :children
        parent = sessions.find { |s| s["id"] == @session_picker_parent_id }
        parent&.dig("children") || []
      end
    end

    # Returns the visible items for the current page of the current mode.
    # Each item is a Hash with :type (:root or :child), :data, and :parent_id (for children).
    #
    # @return [Array<Hash>] visible items for the current page
    def session_picker_visible_items
      all = session_picker_all_items_for_mode
      start = @session_picker_page * Settings.session_picker_page_size
      page = all[start, Settings.session_picker_page_size] || []

      page.map do |item|
        case @session_picker_mode
        when :root
          {type: :root, data: item}
        when :children
          {type: :child, data: item, parent_id: @session_picker_parent_id}
        end
      end
    end

    # @return [Boolean] true when more items exist beyond the current page
    def session_picker_has_more?
      total = session_picker_all_items_for_mode.size
      ((@session_picker_page + 1) * Settings.session_picker_page_size) < total
    end

    # @return [Integer] number of items beyond the current page
    def session_picker_remaining_count
      total = session_picker_all_items_for_mode.size
      [total - ((@session_picker_page + 1) * Settings.session_picker_page_size), 0].max
    end

    # Handles Escape in the session picker. In children mode, returns to root.
    # In root mode, closes the picker.
    # @return [void]
    def handle_session_picker_escape
      if @session_picker_mode == :children
        return_to_root_sessions
      else
        @session_picker_active = false
      end
    end

    # Drills into the children of the selected root session.
    # Only available in root mode on sessions with children.
    #
    # @param visible [Array<Hash>] current page items from {#session_picker_visible_items}
    # @return [void]
    def drill_into_children(visible)
      return unless @session_picker_mode == :root

      item = visible[@session_picker_index]
      return unless item&.dig(:type) == :root

      session = item[:data]
      return unless session["children"]&.any?

      @session_picker_mode = :children
      @session_picker_parent_id = session["id"]
      @session_picker_page = 0
      @session_picker_index = 0
    end

    # Returns from children mode to root sessions view.
    # @return [void]
    def return_to_root_sessions
      return unless @session_picker_mode == :children

      @session_picker_mode = :root
      @session_picker_parent_id = nil
      @session_picker_page = 0
      @session_picker_index = 0
    end

    # Advances to the next page of sessions in the current mode.
    # @return [void]
    def load_more_sessions
      @session_picker_page += 1
      @session_picker_index = 0
    end

    # Switches to the session selected in the picker and closes the overlay.
    #
    # @param visible [Array<Hash>] current page items from {#session_picker_visible_items}
    # @return [void]
    def select_session_picker_item(visible)
      item = visible[@session_picker_index]
      return unless item

      @session_picker_active = false
      @screens[:chat].switch_session(item[:data]["id"])
    end

    # Renders the session picker overlay in the sidebar.
    # Shows paginated root sessions or children with drill-down navigation.
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
        visible = session_picker_visible_items
        @session_picker_index = @session_picker_index.clamp(0, [visible.size - 1, 0].max)

        lines = visible.each_with_index.flat_map do |item, idx|
          if item[:type] == :root
            format_root_session_entry(tui, item[:data], idx, current_id)
          else
            format_child_session_entry(tui, item[:data], idx, current_id)
          end
        end

        lines.concat(format_load_more_entry(tui)) if session_picker_has_more?

        if lines.empty?
          lines = [tui.line(spans: [
            tui.span(content: "No sessions", style: tui.style(fg: "dark_gray"))
          ])]
        end
      end

      picker = tui.paragraph(
        text: lines,
        block: tui.block(
          title: session_picker_title,
          borders: [:all],
          border_type: :rounded,
          border_style: {fg: "cyan"}
        )
      )
      frame.render_widget(picker, area)
    end

    # Returns the picker title based on the current navigation mode.
    #
    # @return [String] "Sessions" for root mode, "← #N" for children mode
    def session_picker_title
      case @session_picker_mode
      when :root then "Sessions"
      when :children then "#{BACK_ARROW} ##{@session_picker_parent_id}"
      end
    end

    # Formats a root session entry with drill-in arrow and child count.
    #
    # @param tui [RatatuiRuby] TUI rendering API
    # @param session [Hash] serialized session from the brain
    # @param idx [Integer] position in the current page
    # @param current_id [Integer] ID of the currently active session
    # @return [Array<RatatuiRuby::Widgets::Line>]
    def format_root_session_entry(tui, session, idx, current_id)
      selected = idx == @session_picker_index
      is_current = session["id"] == current_id
      children = session["children"] || []

      hotkey = picker_hotkey(idx)
      prefix = hotkey ? "[#{hotkey}]" : "   "
      marker = is_current ? "*" : " "
      arrow = children.any? ? CHILDREN_ARROW : " "

      display_name = session["name"] || "##{session["id"]}"
      count = "#{session["message_count"]}msg"
      time = format_relative_time(session["updated_at"])
      child_info = children.any? ? " (#{children.size})" : ""

      label = "#{prefix}#{marker}#{arrow}#{display_name} #{count}#{child_info} #{time}"

      style = if selected
        tui.style(fg: "black", bg: "cyan")
      elsif is_current
        tui.style(fg: "cyan", modifiers: [:bold])
      else
        tui.style(fg: "white")
      end

      [tui.line(spans: [tui.span(content: label, style: style)])]
    end

    # Formats a child session entry with hotkey, status indicator, and agent name.
    #
    # @param tui [RatatuiRuby] TUI rendering API
    # @param child [Hash] serialized child session from the brain
    # @param idx [Integer] position in the current page
    # @param current_id [Integer] ID of the currently active session
    # @return [Array<RatatuiRuby::Widgets::Line>]
    def format_child_session_entry(tui, child, idx, current_id)
      selected = idx == @session_picker_index
      is_current = child["id"] == current_id

      hotkey = picker_hotkey(idx)
      prefix = hotkey ? "[#{hotkey}]" : "   "
      marker = is_current ? "*" : " "
      status = child["processing"] ? CHILD_STATUS_RUNNING : CHILD_STATUS_DONE
      status_color = child["processing"] ? "yellow" : "green"
      display_name = child["name"] || UNNAMED_SUBAGENT_LABEL

      label = "#{prefix}#{marker}#{status} #{display_name}"

      style = if selected
        tui.style(fg: "black", bg: "cyan")
      elsif is_current
        tui.style(fg: "cyan", modifiers: [:bold])
      else
        tui.style(fg: status_color)
      end

      [tui.line(spans: [tui.span(content: label, style: style)])]
    end

    # Formats the "Load more" entry shown when additional pages exist.
    #
    # @param tui [RatatuiRuby] TUI rendering API
    # @return [Array<RatatuiRuby::Widgets::Line>]
    def format_load_more_entry(tui)
      remaining = session_picker_remaining_count
      label = "[0]  Load more (#{remaining})"
      [tui.line(spans: [tui.span(content: label, style: tui.style(fg: "dark_gray"))])]
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
        tui.line(spans: [tui.span(content: "#{" " * PICKER_PREFIX_WIDTH}#{VIEW_MODE_LABELS[mode]}", style: desc_style)])
      ]
    end

    # -- Token setup popup -----------------------------------------------

    # Opens the token setup popup and resets all input state.
    # Can be triggered manually via C-a → a or automatically when the
    # brain broadcasts authentication_required.
    # @return [void]
    def activate_token_setup
      @token_setup_active = true
      @token_input_buffer.clear
      @token_setup_error = nil
      @token_setup_warning = nil
      @token_setup_status = :idle
    end

    # Closes the token setup popup and resets all state.
    # @return [void]
    def close_token_setup
      @token_setup_active = false
      @token_input_buffer.clear
      @token_setup_error = nil
      @token_setup_warning = nil
      @token_setup_status = :idle
    end

    # Polls the chat screen for authentication signals and token save results.
    # Called every render frame so the popup reacts to server responses.
    #
    # State transitions:
    #   authentication_required signal → activates popup (if not already open)
    #   token_saved result             → @token_setup_status becomes :success
    #   token_error result             → @token_setup_status becomes :error
    #
    # @return [void]
    def check_token_setup_signals
      chat = @screens[:chat]

      if chat.authentication_required && !@token_setup_active
        activate_token_setup
        chat.clear_authentication_required
      end

      result = chat.consume_token_save_result
      return unless result

      if result[:success]
        @token_setup_status = :success
        @token_setup_error = nil
        @token_setup_warning = result[:warning]
      else
        @token_setup_status = :error
        @token_setup_error = result[:message]
        @token_setup_warning = nil
      end
    end

    # Dispatches keyboard and paste events while the token setup popup is open.
    #
    # @param event [RatatuiRuby::Event] input event
    # @return [nil]
    def handle_token_setup(event)
      # In success state, any key closes the popup
      if @token_setup_status == :success
        close_token_setup if event.key? || event.paste?
        return nil
      end

      # During validation, ignore all input
      return nil if @token_setup_status == :validating

      if event.paste?
        @token_input_buffer.insert(event.content)
        @token_setup_error = nil
        @token_setup_status = :idle
        return nil
      end

      return nil unless event.key?

      if event.esc?
        close_token_setup
      elsif event.enter?
        submit_token
      elsif event.backspace?
        @token_input_buffer.backspace
        @token_setup_error = nil
        @token_setup_status = :idle
      elsif event.delete?
        @token_input_buffer.delete
      elsif event.left?
        @token_input_buffer.move_left
      elsif event.right?
        @token_input_buffer.move_right
      elsif event.home?
        @token_input_buffer.move_home
      elsif event.end?
        @token_input_buffer.move_end
      elsif printable_token_char?(event)
        @token_input_buffer.insert(event.code)
        @token_setup_error = nil
        @token_setup_status = :idle
      end

      nil
    end

    # Sends the entered token to the brain for validation and storage.
    # @return [void]
    def submit_token
      token = @token_input_buffer.text.strip
      return if token.empty?

      @token_setup_status = :validating
      @token_setup_error = nil
      @cable_client.save_token(token)
    end

    # @param event [RatatuiRuby::Event] keyboard event
    # @return [Boolean] true if the key is a printable character without ctrl
    def printable_token_char?(event)
      return false if event.modifiers&.include?("ctrl")

      event.code.length == 1 && event.code.match?(PRINTABLE_CHAR)
    end

    # Renders the token setup popup as a centered overlay on the full terminal area.
    # Uses the Clear widget to prevent background content from bleeding through.
    #
    # @param frame [RatatuiRuby::Frame] terminal frame
    # @param area [RatatuiRuby::Rect] full terminal area
    # @param tui [RatatuiRuby] TUI rendering API
    # @return [void]
    def render_token_setup_popup(frame, area, tui)
      popup_area = centered_popup_area(tui, area)

      frame.render_widget(tui.clear, popup_area)

      border_color = case @token_setup_status
      when :success then "green"
      when :error then "red"
      else "yellow"
      end

      lines = build_token_setup_lines(tui)

      popup = tui.paragraph(
        text: lines,
        wrap: true,
        block: tui.block(
          title: "Anthropic Token Setup",
          borders: [:all],
          border_type: :rounded,
          border_style: {fg: border_color}
        )
      )
      frame.render_widget(popup, popup_area)

      set_token_input_cursor(frame, popup_area) if token_cursor_visible?
    end

    # Builds the text lines for the token setup popup.
    # @param tui [RatatuiRuby] TUI rendering API
    # @return [Array<RatatuiRuby::Widgets::Line>]
    def build_token_setup_lines(tui)
      lines = []

      # Status
      status_text, status_color = token_status_display
      lines << tui.line(spans: [
        tui.span(content: "Status: ", style: tui.style(fg: "dark_gray")),
        tui.span(content: status_text, style: tui.style(fg: status_color, modifiers: [:bold]))
      ])
      lines << tui.line(spans: [tui.span(content: "")])

      # Instructions
      lines << tui.line(spans: [
        tui.span(content: "Run ", style: tui.style(fg: "white")),
        tui.span(content: "claude setup-token", style: tui.style(fg: "cyan", modifiers: [:bold])),
        tui.span(content: " to get", style: tui.style(fg: "white"))
      ])
      lines << tui.line(spans: [
        tui.span(content: "your token, then paste it here.", style: tui.style(fg: "white"))
      ])
      lines << tui.line(spans: [tui.span(content: "")])

      # Token input
      masked = mask_token(@token_input_buffer.text)
      lines << tui.line(spans: [
        tui.span(content: "Token:", style: tui.style(fg: "white", modifiers: [:bold]))
      ])
      lines << tui.line(spans: [
        tui.span(content: "> #{masked}", style: tui.style(fg: "white"))
      ])
      lines << tui.line(spans: [tui.span(content: "")])

      # Error or success message
      if @token_setup_error
        lines << tui.line(spans: [
          tui.span(content: @token_setup_error, style: tui.style(fg: "red"))
        ])
        lines << tui.line(spans: [tui.span(content: "")])
      end

      if @token_setup_status == :success
        lines << if @token_setup_warning
          tui.line(spans: [
            tui.span(content: "Token saved (API unavailable, validation skipped)", style: tui.style(fg: "yellow", modifiers: [:bold]))
          ])
        else
          tui.line(spans: [
            tui.span(content: "Token saved and validated!", style: tui.style(fg: "green", modifiers: [:bold]))
          ])
        end
        lines << tui.line(spans: [tui.span(content: "")])
      end

      # Hints
      hint = case @token_setup_status
      when :success then "[any key] Close"
      when :validating then "Validating..."
      else "[Enter] Save  [Esc] Cancel"
      end
      lines << tui.line(spans: [
        tui.span(content: hint, style: tui.style(fg: "dark_gray"))
      ])

      lines
    end

    # @return [Array(String, String)] [status_text, color] for the current token setup state
    def token_status_display
      case @token_setup_status
      when :success
        @token_setup_warning ? ["Saved (unverified)", "yellow"] : ["Valid", "green"]
      when :validating
        ["Validating...", "yellow"]
      when :error
        ["Invalid", "red"]
      else
        if @token_input_buffer.text.empty?
          ["Not configured", "dark_gray"]
        else
          ["Ready to save", "cyan"]
        end
      end
    end

    # Masks an Anthropic token for display: shows the first Settings.token_mask_visible
    # characters (the prefix) and replaces the rest with stars.
    #
    # @param token [String] raw token text
    # @return [String] masked display text
    def mask_token(token)
      return "" if token.empty?
      return token if token.length <= Settings.token_mask_visible

      visible = token[0...Settings.token_mask_visible]
      hidden_count = [token.length - Settings.token_mask_visible, Settings.token_mask_stars].min
      "#{visible}#{"*" * hidden_count}..."
    end

    # @return [Boolean] true when the blinking cursor should be shown in the input field
    def token_cursor_visible?
      @token_setup_status == :idle || @token_setup_status == :error
    end

    # Positions the terminal cursor on the token input line inside the popup.
    # The input ">" line is at a fixed offset from the popup top.
    #
    # @param frame [RatatuiRuby::Frame] terminal frame
    # @param popup_area [RatatuiRuby::Rect] popup rectangle
    # @return [void]
    def set_token_input_cursor(frame, popup_area)
      # Content line offsets within the popup (after top border):
      # 0: Status  1: blank  2: Instructions L1  3: Instructions L2
      # 4: blank   5: Token:  6: > (input)
      input_line_offset = 7 # border (1) + 6 content lines

      masked = mask_token(@token_input_buffer.text)
      prompt_width = 2 # "> " prefix before the masked token text
      cursor_x = popup_area.x + 1 + prompt_width + masked.length # border + prompt + text
      cursor_y = popup_area.y + input_line_offset

      return unless cursor_x < popup_area.x + popup_area.width - 1 &&
        cursor_y < popup_area.y + popup_area.height - 1

      frame.set_cursor_position(cursor_x, cursor_y)
    end

    # Calculates a centered rectangle for the popup overlay.
    #
    # @param tui [RatatuiRuby] TUI rendering API
    # @param area [RatatuiRuby::Rect] full terminal area
    # @return [RatatuiRuby::Rect] centered popup area
    def centered_popup_area(tui, area)
      popup_height = [Settings.token_popup_height, area.height - 2].min
      v_margin = [(area.height - popup_height) / 2, 0].max

      _, center_v, _ = tui.split(
        area,
        direction: :vertical,
        constraints: [
          tui.constraint_length(v_margin),
          tui.constraint_length(popup_height),
          tui.constraint_fill(1)
        ]
      )

      popup_width = (area.width * 60 / 100).clamp(Settings.token_popup_min_width, area.width - 2)
      h_margin = [(area.width - popup_width) / 2, 0].max

      _, center, _ = tui.split(
        center_v,
        direction: :horizontal,
        constraints: [
          tui.constraint_length(h_margin),
          tui.constraint_length(popup_width),
          tui.constraint_fill(1)
        ]
      )

      center
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

      @watchdog_thread.join(Settings.watchdog_shutdown_timeout)
      @watchdog_thread.kill if @watchdog_thread.alive?
      @watchdog_thread = nil
    end

    # Opens {CONTROLLING_TERMINAL} every +terminal.check_interval+ seconds.
    # File.open (not File.stat) is required because stat only checks the
    # filesystem entry which always exists; open actually probes the device.
    # When the terminal disappears, calls {#handle_terminal_loss}.
    # Exits silently in non-TTY environments (CI, test suites).
    # @see CONTROLLING_TERMINAL
    # @see TUI::Settings.terminal_check_interval
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
        sleep Settings.terminal_check_interval
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
