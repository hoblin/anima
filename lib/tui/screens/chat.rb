# frozen_string_literal: true

require_relative "../input_buffer"

module TUI
  module Screens
    class Chat
      MIN_INPUT_HEIGHT = 3
      PRINTABLE_CHAR = /\A[[:print:]]\z/

      ROLE_USER = "user"
      ROLE_ASSISTANT = "assistant"
      ROLE_LABELS = {ROLE_USER => "You", ROLE_ASSISTANT => "Anima"}.freeze

      SCROLL_STEP = 1
      MOUSE_SCROLL_STEP = 2

      TOOL_ICON = "\u{1F527}"
      CHECKMARK = "\u2713"

      VIEW_MODES = %w[basic verbose debug].freeze

      attr_reader :message_store, :scroll_offset, :session_info, :view_mode

      # @param cable_client [TUI::CableClient] WebSocket client connected to the brain
      # @param message_store [TUI::MessageStore, nil] injectable for testing
      def initialize(cable_client:, message_store: nil)
        @cable_client = cable_client
        @message_store = message_store || MessageStore.new
        @input_buffer = InputBuffer.new
        @loading = false
        @scroll_offset = 0
        @auto_scroll = true
        @visible_height = 0
        @max_scroll = 0
        @input_scroll_offset = 0
        @view_mode = "basic"
        @session_info = {id: cable_client.session_id, message_count: 0}
      end

      def messages
        @message_store.messages
      end

      # @return [String] current input text (delegates to InputBuffer)
      def input
        @input_buffer.text
      end

      # @return [Integer] current cursor position (delegates to InputBuffer)
      def cursor_pos
        @input_buffer.cursor_pos
      end

      def render(frame, area, tui)
        process_incoming_messages

        input_height = calculate_input_height(tui, area.width, area.height)

        chat_area, input_area = tui.split(
          area,
          direction: :vertical,
          constraints: [
            tui.constraint_fill(1),
            tui.constraint_length(input_height)
          ]
        )

        render_messages(frame, chat_area, tui)
        render_input(frame, input_area, tui)
      end

      # Scrolling and cursor navigation bypass the loading guard so users can
      # read chat history during LLM calls.
      def handle_event(event)
        return handle_mouse_event(event) if event.mouse?
        return handle_paste_event(event) if event.paste?
        return handle_scroll_key(event) if event.page_up? || event.page_down?
        return handle_scroll_key(event) if event.up? || event.down?

        return false if @loading

        if event.enter?
          submit_message
          true
        elsif event.backspace?
          @input_buffer.backspace
          true
        elsif event.delete?
          @input_buffer.delete
          true
        elsif event.left?
          @input_buffer.move_left
        elsif event.right?
          @input_buffer.move_right
        elsif event.home?
          @input_buffer.move_home
        elsif event.end?
          @input_buffer.move_end
        elsif printable_char?(event) && !@input_buffer.full?
          @input_buffer.insert(event.code)
        else
          false
        end
      end

      # Creates a new session through the WebSocket protocol.
      # The brain creates the session, switches the channel stream, and sends
      # a session_changed signal followed by (empty) history. The client-side
      # state reset happens when session_changed is received.
      def new_session
        @cable_client.create_session
      end

      # Cycles to the next view mode and requests the server to switch.
      # The server broadcasts the mode change and re-transmits the viewport
      # decorated in the new mode to all connected clients.
      def cycle_view_mode
        current_index = VIEW_MODES.index(@view_mode) || 0
        next_mode = VIEW_MODES[(current_index + 1) % VIEW_MODES.size]
        @cable_client.change_view_mode(next_mode)
      end

      def finalize
      end

      def loading?
        @loading
      end

      private

      # Drains the WebSocket message queue and feeds events to the message store
      def process_incoming_messages
        @cable_client.drain_messages.each do |msg|
          action = msg["action"]
          type = msg["type"]

          case action
          when "session_changed"
            handle_session_changed(msg)
          when "view_mode_changed"
            handle_view_mode_changed(msg)
          when "view_mode"
            @view_mode = msg["view_mode"] if msg["view_mode"]
          when "sessions_list"
            @sessions_list = msg["sessions"]
          when "error"
            # Silently ignored — no user-facing error display yet
          else
            case type
            when "connection"
              handle_connection_status(msg)
            when "user_message"
              @message_store.process_event(msg)
              @session_info[:message_count] += 1
              @loading = true
            when "agent_message"
              @message_store.process_event(msg)
              @session_info[:message_count] += 1
              @loading = false
            else # tool_call, tool_response, and other event types
              @message_store.process_event(msg)
            end
          end
        end
      end

      # Reacts to connection lifecycle changes from the WebSocket client.
      # Clears stale state on (re)subscription so fresh history from the server
      # replaces any messages displayed before the disconnect.
      def handle_connection_status(msg)
        case msg["status"]
        when "subscribed"
          @message_store.clear
          @loading = false
          @session_info[:message_count] = 0
        when "disconnected", "failed"
          @loading = false
        end
      end

      def handle_session_changed(msg)
        new_id = msg["session_id"]
        @cable_client.update_session_id(new_id)
        @message_store.clear
        @view_mode = msg["view_mode"] if msg["view_mode"]
        @session_info = {id: new_id, message_count: msg["message_count"] || 0}
        @input_buffer.clear
        @loading = false
        @scroll_offset = 0
        @auto_scroll = true
        @input_scroll_offset = 0
      end

      # Handles server broadcast of view mode change. Clears the message store
      # in preparation for the re-decorated viewport events that follow.
      def handle_view_mode_changed(msg)
        @view_mode = msg["view_mode"] if msg["view_mode"]
        @message_store.clear
        @scroll_offset = 0
        @auto_scroll = true
      end

      def render_messages(frame, area, tui)
        lines = build_message_lines(tui)

        if @loading
          lines << tui.line(spans: [
            tui.span(content: "Thinking...", style: tui.style(fg: "yellow", modifiers: [:bold]))
          ])
        end

        if lines.empty?
          lines << tui.line(spans: [
            tui.span(content: "Type a message to start chatting.", style: tui.style(fg: "dark_gray"))
          ])
        end

        inner_width = [area.width - 2, 1].max
        @visible_height = [area.height - 2, 0].max

        content_widget = tui.paragraph(text: lines, wrap: true, style: tui.style(fg: "white"))
        content_height = content_widget.line_count(inner_width)

        @max_scroll = [content_height - @visible_height, 0].max
        @scroll_offset = @max_scroll if @auto_scroll
        @scroll_offset = @scroll_offset.clamp(0, @max_scroll)

        widget = tui.paragraph(
          text: lines,
          wrap: true,
          style: tui.style(fg: "white"),
          scroll: [@scroll_offset, 0],
          block: tui.block(
            title: "Chat",
            borders: [:all],
            border_type: :rounded,
            border_style: {fg: "cyan"}
          )
        )
        frame.render_widget(widget, area)

        return unless @max_scroll > 0

        scrollbar = tui.scrollbar(
          content_length: @max_scroll,
          position: @scroll_offset,
          orientation: :vertical_right,
          thumb_style: {fg: "cyan"},
          track_symbol: "\u2502",
          track_style: {fg: "dark_gray"}
        )
        frame.render_widget(scrollbar, area)
      end

      def build_message_lines(tui)
        messages.flat_map do |entry|
          case entry[:type]
          when :rendered
            build_rendered_lines(tui, entry)
          when :tool_counter
            build_tool_counter_lines(tui, entry)
          when :message
            build_chat_message_lines(tui, entry)
          end
        end
      end

      # Renders a tool activity counter (e.g. "🔧 Tools: 2/2 ✓").
      # Green when all calls have responses, yellow while in-progress.
      # @param tui [RatatuiRuby] TUI rendering API
      # @param counter [Hash] entry shaped `{type: :tool_counter, calls:, responses:}`
      # @return [Array<RatatuiRuby::Widgets::Line>] counter line + blank separator
      def build_tool_counter_lines(tui, counter)
        calls = counter[:calls]
        responses = counter[:responses]
        complete = calls == responses
        label = "#{TOOL_ICON} Tools: #{calls}/#{responses}#{" #{CHECKMARK}" if complete}"
        color = complete ? "green" : "yellow"
        [
          tui.line(spans: [tui.span(content: label, style: tui.style(fg: color))]),
          tui.line(spans: [tui.span(content: "")])
        ]
      end

      # Renders pre-decorated lines from the server. Applies basic styling
      # based on the role prefix (green for user, cyan for agent).
      # @param tui [RatatuiRuby] TUI rendering API
      # @param entry [Hash] entry shaped `{type: :rendered, lines:}`
      # @return [Array<RatatuiRuby::Widgets::Line>] rendered lines + blank separator
      def build_rendered_lines(tui, entry)
        lines = entry[:lines].map do |text|
          style = if text.start_with?("You: ")
            tui.style(fg: "green")
          elsif text.start_with?("Anima: ")
            tui.style(fg: "cyan")
          else
            tui.style(fg: "white")
          end
          tui.line(spans: [tui.span(content: text, style: style)])
        end
        lines << tui.line(spans: [tui.span(content: "")])
      end

      def build_chat_message_lines(tui, msg)
        role = msg[:role]
        role_style = (role == ROLE_USER) ? tui.style(fg: "green", modifiers: [:bold]) : tui.style(fg: "cyan", modifiers: [:bold])

        label = ROLE_LABELS.fetch(role, role)
        content_lines = msg[:content].to_s.split("\n", -1)

        lines = [tui.line(spans: [
          tui.span(content: "#{label}: ", style: role_style),
          tui.span(content: content_lines.first.to_s)
        ])]
        content_lines.drop(1).each { |text| lines << tui.line(spans: [tui.span(content: text)]) }
        lines << tui.line(spans: [tui.span(content: "")])
      end

      # Dynamically calculates input area height based on wrapped content.
      # Clamped between MIN_INPUT_HEIGHT and 50% of available height.
      def calculate_input_height(_tui, area_width, area_height)
        inner_width = [area_width - 2, 1].max

        content_height = "> #{@input_buffer.text}".split("\n", -1).sum { |pline|
          word_wrap_segments(pline, inner_width).length
        }
        desired = content_height + 2 # top + bottom border

        max_height = [area_height / 2, MIN_INPUT_HEIGHT].max
        desired.clamp(MIN_INPUT_HEIGHT, max_height)
      end

      def render_input(frame, area, tui)
        disabled = @loading || !connected?
        styles = input_styles(tui, disabled)

        title = input_title

        inner_width = [area.width - 2, 1].max
        input_visible_height = [area.height - 2, 0].max

        lines = build_input_lines(tui, styles[:text], inner_width)
        input_scroll = calculate_cursor_and_scroll(inner_width, input_visible_height)

        widget = tui.paragraph(
          text: lines,
          scroll: [input_scroll, 0],
          block: tui.block(
            title: title,
            titles: disabled ? [] : [
              {content: "Enter send", position: :bottom, alignment: :center}
            ],
            borders: [:all],
            border_type: :rounded,
            border_style: styles[:border]
          )
        )
        frame.render_widget(widget, area)

        return if disabled

        cursor_x = area.x + 1 + @cursor_visual_col
        cursor_y = area.y + 1 + @cursor_visual_row - input_scroll

        if cursor_y >= area.y + 1 && cursor_y < area.y + area.height - 1
          frame.set_cursor_position(cursor_x, cursor_y)
        end
      end

      def input_styles(tui, disabled)
        {
          text: disabled ? tui.style(fg: "dark_gray") : tui.style(fg: "white"),
          border: disabled ? {fg: "dark_gray"} : {fg: "green"}
        }
      end

      def input_title
        if @loading
          "Waiting..."
        elsif !connected?
          "Disconnected"
        else
          "Input"
        end
      end

      # Builds input text as pre-wrapped Line objects for the Paragraph widget.
      # Lines are word-wrapped here so the Paragraph renders without its own
      # wrapping, keeping cursor positioning in sync with the displayed text.
      def build_input_lines(tui, text_style, inner_width)
        display = "> #{@input_buffer.text}"
        display.split("\n", -1).flat_map { |pline|
          word_wrap_segments(pline, inner_width).map { |start, len|
            tui.line(spans: [tui.span(content: pline[start, len], style: text_style)])
          }
        }
      end

      # Computes cursor visual position (row, column) and input scroll offset.
      # Uses the full physical line's wrap segments so cursor placement matches
      # the actual rendered word-wrap breaks (not prefix-based approximations).
      # @return [Integer] input scroll offset
      def calculate_cursor_and_scroll(inner_width, visible_height)
        before_display = "> #{@input_buffer.text[0...@input_buffer.cursor_pos]}"
        full_display = "> #{@input_buffer.text}"

        before_physical = before_display.split("\n", -1)
        full_physical = full_display.split("\n", -1)

        cursor_line_idx = before_physical.length - 1

        # Count visual rows for physical lines above the cursor's line
        row = 0
        full_physical[0...cursor_line_idx].each { |pline|
          row += word_wrap_segments(pline, inner_width).length
        }

        # Locate cursor within the full physical line's wrap segments
        full_line = full_physical[cursor_line_idx] || ""
        segments = word_wrap_segments(full_line, inner_width)
        cursor_offset = (before_physical.last || "").length

        col = cursor_offset
        segments.each_with_index do |(start, len), idx|
          if cursor_offset <= start + len
            row += idx
            col = cursor_offset - start
            break
          end
        end

        @cursor_visual_row = [row, 0].max
        @cursor_visual_col = col

        # Snap scroll window: pull up if cursor is above view, push down if below
        return 0 if visible_height <= 0

        if @cursor_visual_row < @input_scroll_offset
          @input_scroll_offset = @cursor_visual_row
        elsif @cursor_visual_row >= @input_scroll_offset + visible_height
          @input_scroll_offset = @cursor_visual_row - visible_height + 1
        end

        @input_scroll_offset
      end

      # Word-wraps a single physical line into segments.
      # Breaks at word boundaries (spaces) when possible, falls back to
      # character-level breaks for words exceeding the width.
      # @param text [String] text to wrap (should not contain newlines)
      # @param width [Integer] maximum visual line width
      # @return [Array<Array(Integer, Integer)>] [start_position, length] pairs
      def word_wrap_segments(text, width)
        return [[0, text.length]] if text.length <= width || width <= 0

        segments = []
        pos = 0

        while pos < text.length
          remaining = text.length - pos
          if remaining <= width
            segments << [pos, remaining]
            break
          end

          break_at = text.rindex(" ", pos + width - 1)
          if break_at && break_at > pos
            segments << [pos, break_at - pos]
            pos = break_at + 1
          else
            segments << [pos, width]
            pos += width
          end
        end

        segments
      end

      def submit_message
        return if @input_buffer.text.strip.empty?
        return unless connected?

        text = @input_buffer.consume
        @input_scroll_offset = 0
        @cable_client.speak(text)
      end

      # Dispatches arrow and page keys to {#scroll_up} or {#scroll_down}.
      # @return [true] always redraws after scrolling
      def handle_scroll_key(event)
        if event.up?
          scroll_up(SCROLL_STEP)
        elsif event.down?
          scroll_down(SCROLL_STEP)
        elsif event.page_up?
          scroll_up(@visible_height)
        elsif event.page_down?
          scroll_down(@visible_height)
        end
        true
      end

      # Handles mouse wheel scroll events; ignores other mouse events
      # @return [Boolean] true if the event was a scroll wheel event
      def handle_mouse_event(event)
        if event.scroll_up?
          scroll_up(MOUSE_SCROLL_STEP)
          true
        elsif event.scroll_down?
          scroll_down(MOUSE_SCROLL_STEP)
          true
        else
          false
        end
      end

      # Scrolls the viewport up, clamping at the top.
      # Disables auto-scroll when the user moves away from the bottom.
      # @param lines [Integer] number of lines to scroll
      def scroll_up(lines)
        @scroll_offset = [@scroll_offset - lines, 0].max
        @auto_scroll = @scroll_offset >= @max_scroll
      end

      # Scrolls the viewport down, clamping at max_scroll.
      # Re-enables auto-scroll when the user reaches the bottom.
      # @param lines [Integer] number of lines to scroll
      def scroll_down(lines)
        @scroll_offset = [@scroll_offset + lines, @max_scroll].min
        @auto_scroll = @scroll_offset >= @max_scroll
      end

      # @return [Boolean] true when WebSocket is fully subscribed and ready
      def connected?
        @cable_client.status == :subscribed
      end

      # Inserts pasted clipboard content at cursor position.
      # Paste is dispatched before the generic loading guard in {#handle_event}
      # but still blocked during loading to match the visually-disabled input.
      # @param event [RatatuiRuby::Event::Paste] paste event with content
      # @return [Boolean] true if content was inserted, false if loading or buffer full
      def handle_paste_event(event)
        return false if @loading || @input_buffer.full?

        @input_buffer.insert(event.content)
      end

      def printable_char?(event)
        return false if event.modifiers&.include?("ctrl")

        event.code.length == 1 && event.code.match?(PRINTABLE_CHAR)
      end
    end
  end
end
