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

      attr_reader :input, :message_collector, :session

      def initialize(message_collector: nil, persister: nil, session: nil)
        @message_collector = message_collector || Events::Subscribers::MessageCollector.new
        @input = ""
        @loading = false
        @client = nil

        @session = session || Session.order(id: :desc).first || Session.create!
        load_session_messages
        @persister = persister || Events::Subscribers::Persister.new(@session)

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

      def handle_event(event)
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
        @session = Session.create!
        @persister.session = @session
        @message_collector.clear
        @input = ""
        @loading = false
      end

      def finalize
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

        widget = tui.paragraph(
          text: lines,
          wrap: true,
          block: tui.block(
            title: "Chat",
            borders: [:all],
            border_type: :rounded,
            border_style: {fg: "cyan"}
          )
        )
        frame.render_widget(widget, area)
      end

      def build_message_lines(tui)
        messages.flat_map do |msg|
          role_style = if msg[:role] == ROLE_USER
            tui.style(fg: "green", modifiers: [:bold])
          else
            tui.style(fg: "cyan", modifiers: [:bold])
          end

          label = ROLE_LABELS.fetch(msg[:role], msg[:role])

          [
            tui.line(spans: [
              tui.span(content: "#{label}: ", style: role_style),
              tui.span(content: msg[:content], style: tui.style(fg: "white"))
            ]),
            tui.line(spans: [tui.span(content: "", style: tui.style(fg: "white"))])
          ]
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

        Events::Bus.emit(Events::UserMessage.new(content: text, session_id: @session.id))
        @input = ""
        @loading = true

        Thread.new do
          @client ||= LLM::Client.new
          @registry ||= build_tool_registry
          viewport_messages = @session.messages_for_llm
          response = @client.chat_with_tools(
            viewport_messages,
            registry: @registry,
            session_id: @session.id
          )
          Events::Bus.emit(Events::AgentMessage.new(content: response, session_id: @session.id))
        rescue => e
          Events::Bus.emit(Events::AgentMessage.new(content: "Error: #{e.message}", session_id: @session.id))
        ensure
          @loading = false
        end
      end

      def build_tool_registry
        registry = Tools::Registry.new
        registry.register(Tools::WebGet)
        registry.register(Tools::Bash)
        registry
      end

      def load_session_messages
        @session.events.where(event_type: Events::Subscribers::MessageCollector::DISPLAYABLE_TYPES).each do |event|
          @message_collector.messages_push({
            role: Events::Subscribers::MessageCollector::ROLE_MAP.fetch(event.event_type),
            content: event.payload["content"].to_s
          })
        end
      end

      def printable_char?(event)
        return false if event.modifiers&.include?("ctrl")

        event.code.length == 1 && event.code.match?(PRINTABLE_CHAR)
      end
    end
  end
end
