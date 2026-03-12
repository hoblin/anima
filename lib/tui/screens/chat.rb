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

      attr_reader :message_store, :scroll_offset, :session_info

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
            else
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
        @session_info = {id: new_id, message_count: msg["message_count"] || 0}
        @input_buffer.clear
        @loading = false
        @scroll_offset = 0
        @auto_scroll = true
        @input_scroll_offset = 0
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
        messages.flat_map do |msg|
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
      end

      # Dynamically calculates input area height based on wrapped content.
      # Clamped between MIN_INPUT_HEIGHT and 50% of available height.
      def calculate_input_height(tui, area_width, area_height)
        inner_width = [area_width - 2, 1].max

        display_lines = "> #{@input_buffer.text}".split("\n", -1).map { |text|
          tui.line(spans: [tui.span(content: text)])
        }

        temp = tui.paragraph(text: display_lines, wrap: true)
        content_height = temp.line_count(inner_width)
        desired = content_height + 2 # top + bottom border

        max_height = [area_height / 2, MIN_INPUT_HEIGHT].max
        desired.clamp(MIN_INPUT_HEIGHT, max_height)
      end

      def render_input(frame, area, tui)
        disabled = @loading || !connected?
        cursor_char = disabled ? "" : "\u2588"
        styles = input_styles(tui, disabled)

        title = input_title

        inner_width = [area.width - 2, 1].max
        input_visible_height = [area.height - 2, 0].max

        lines = build_input_lines(tui, styles[:text], cursor_char)
        input_scroll = calculate_input_scroll(tui, inner_width, input_visible_height)

        widget = tui.paragraph(
          text: lines,
          wrap: true,
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

      # Builds input text as array of Line objects with cursor character inserted
      def build_input_lines(tui, text_style, cursor_char)
        input_text = @input_buffer.text
        pos = @input_buffer.cursor_pos
        display = "> #{input_text[0...pos]}#{cursor_char}#{input_text[pos..]}"

        display.split("\n", -1).map { |text|
          tui.line(spans: [tui.span(content: text, style: text_style)])
        }
      end

      # Scrolls input to keep cursor visible when content exceeds visible height.
      # Measures wrapped line count of text before cursor to find its visual row,
      # then adjusts the scroll window so that row stays in view.
      def calculate_input_scroll(tui, inner_width, visible_height)
        return 0 if visible_height <= 0

        before_display = "> #{@input_buffer.text[0...@input_buffer.cursor_pos]}"
        before_lines = before_display.split("\n", -1).map { |text|
          tui.line(spans: [tui.span(content: text)])
        }

        temp = tui.paragraph(text: before_lines, wrap: true)
        cursor_visual_line = [temp.line_count(inner_width) - 1, 0].max

        # Snap scroll window: pull up if cursor is above view, push down if below
        if cursor_visual_line < @input_scroll_offset
          @input_scroll_offset = cursor_visual_line
        elsif cursor_visual_line >= @input_scroll_offset + visible_height
          @input_scroll_offset = cursor_visual_line - visible_height + 1
        end

        @input_scroll_offset
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
