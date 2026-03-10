# frozen_string_literal: true

module TUI
  module Screens
    class Chat
      INPUT_HEIGHT = 3
      MAX_INPUT_LENGTH = 10_000
      PRINTABLE_CHAR = /\A[[:print:]]\z/

      ROLE_USER = "user"
      ROLE_ASSISTANT = "assistant"
      ROLE_LABELS = {ROLE_USER => "You", ROLE_ASSISTANT => "Anima"}.freeze

      SCROLL_STEP = 1
      MOUSE_SCROLL_STEP = 2

      attr_reader :input, :message_store, :scroll_offset, :session_info

      # @param cable_client [TUI::CableClient] WebSocket client connected to the brain
      # @param message_store [TUI::MessageStore, nil] injectable for testing
      def initialize(cable_client:, message_store: nil)
        @cable_client = cable_client
        @message_store = message_store || MessageStore.new
        @input = ""
        @loading = false
        @scroll_offset = 0
        @auto_scroll = true
        @visible_height = 0
        @max_scroll = 0
        @session_info = {id: cable_client.session_id, message_count: 0}
      end

      def messages
        @message_store.messages
      end

      def render(frame, area, tui)
        process_incoming_messages

        chat_area, input_area = tui.split(
          area,
          direction: :vertical,
          constraints: [
            tui.constraint_fill(1),
            tui.constraint_length(INPUT_HEIGHT)
          ]
        )

        render_messages(frame, chat_area, tui)
        render_input(frame, input_area, tui)
      end

      # Scrolling bypasses the loading guard so users can read chat history during LLM calls
      def handle_event(event)
        return handle_mouse_event(event) if event.mouse?
        return handle_scroll_key(event) if scroll_key?(event)
        return false if @loading

        if event.enter?
          submit_message
          true
        elsif event.backspace?
          @input = @input.chop
          true
        elsif printable_char?(event) && @input.length < MAX_INPUT_LENGTH
          @input += event.code
          true
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
              # Connection status changes handled by App via cable_client.status
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

      def handle_session_changed(msg)
        new_id = msg["session_id"]
        @cable_client.update_session_id(new_id)
        @message_store.clear
        @session_info = {id: new_id, message_count: msg["message_count"] || 0}
        @input = ""
        @loading = false
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

        if @max_scroll > 0
          scrollbar = tui.scrollbar(
            content_length: @max_scroll,
            position: @scroll_offset,
            orientation: :vertical_right,
            thumb_style: {fg: "cyan"},
            track_symbol: "│",
            track_style: {fg: "dark_gray"}
          )
          frame.render_widget(scrollbar, area)
        end
      end

      def build_message_lines(tui)
        messages.flat_map do |msg|
          role_style = if msg[:role] == ROLE_USER
            tui.style(fg: "green", modifiers: [:bold])
          else
            tui.style(fg: "cyan", modifiers: [:bold])
          end

          label = ROLE_LABELS.fetch(msg[:role], msg[:role])
          content_lines = msg[:content].to_s.split("\n", -1)

          lines = [tui.line(spans: [
            tui.span(content: "#{label}: ", style: role_style),
            tui.span(content: content_lines.first.to_s)
          ])]
          content_lines.drop(1).each { |text| lines << tui.line(spans: [tui.span(content: text)]) }
          lines << tui.line(spans: [tui.span(content: "")])
        end
      end

      def render_input(frame, area, tui)
        cursor = @loading ? "" : "\u2588"
        border_style = @loading ? {fg: "dark_gray"} : {fg: "green"}
        text_style = @loading ? tui.style(fg: "dark_gray") : tui.style(fg: "white")

        widget = tui.paragraph(
          text: tui.line(spans: [
            tui.span(content: "> #{@input}#{cursor}", style: text_style)
          ]),
          block: tui.block(
            title: @loading ? "Waiting..." : "Input",
            titles: @loading ? [] : [
              {content: "Enter send", position: :bottom, alignment: :center}
            ],
            borders: [:all],
            border_type: :rounded,
            border_style: border_style
          )
        )
        frame.render_widget(widget, area)
      end

      def submit_message
        text = @input.strip
        return if text.empty?

        @input = ""
        @cable_client.speak(text)
      end

      # @return [Boolean] whether the event is an arrow or page key used for scrolling
      def scroll_key?(event)
        event.up? || event.down? || event.page_up? || event.page_down?
      end

      # Dispatches scroll key events to {#scroll_up} or {#scroll_down}
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

      def printable_char?(event)
        return false if event.modifiers&.include?("ctrl")

        event.code.length == 1 && event.code.match?(PRINTABLE_CHAR)
      end
    end
  end
end
