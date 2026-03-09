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

      attr_reader :input, :message_collector, :session, :scroll_offset

      # @param message_collector [Events::Subscribers::MessageCollector, nil]
      # @param persister [Events::Subscribers::Persister, nil]
      # @param session [Session, nil] conversation session to resume
      # @param shell_session [ShellSession, nil] passed through to {AgentLoop}
      # @param agent_loop [AgentLoop, nil] injectable for testing
      def initialize(message_collector: nil, persister: nil, session: nil, shell_session: nil, agent_loop: nil)
        @message_collector = message_collector || Events::Subscribers::MessageCollector.new
        @input = ""
        @loading = false
        @submit_thread = nil
        @scroll_offset = 0
        @auto_scroll = true
        @visible_height = 0
        @max_scroll = 0

        @session = session || Session.order(id: :desc).first || Session.create!
        load_session_messages
        @persister = persister || Events::Subscribers::Persister.new(@session)
        @agent_loop = agent_loop || AgentLoop.new(session: @session, shell_session: shell_session)

        Events::Bus.subscribe(@message_collector)
        Events::Bus.subscribe(@persister)
      end

      def messages
        @message_collector.messages
      end

      def render(frame, area, tui)
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

      def new_session
        @submit_thread&.join
        @agent_loop.finalize
        @session = Session.create!
        @persister.session = @session
        @message_collector.clear
        @input = ""
        @loading = false
        @scroll_offset = 0
        @auto_scroll = true
        @agent_loop = AgentLoop.new(session: @session)
      end

      def finalize
        @submit_thread&.join
        @agent_loop.finalize
        Events::Bus.unsubscribe(@message_collector)
        Events::Bus.unsubscribe(@persister)
      end

      def loading?
        @loading
      end

      private

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
        @loading = true

        @submit_thread = Thread.new do
          @agent_loop.process(text)
        ensure
          @loading = false
        end
      end

      def load_session_messages
        @session.events.where(event_type: Events::Subscribers::MessageCollector::DISPLAYABLE_TYPES).each do |event|
          @message_collector.messages_push({
            role: Events::Subscribers::MessageCollector::ROLE_MAP.fetch(event.event_type),
            content: event.payload["content"].to_s
          })
        end
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
