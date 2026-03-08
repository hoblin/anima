# frozen_string_literal: true

module TUI
  module Screens
    class Chat
      INPUT_HEIGHT = 3

      attr_reader :messages, :input, :loading

      def initialize
        @messages = []
        @input = ""
        @loading = false
        @client = nil
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
        elsif printable_char?(event)
          @input += event.code
          true
        else
          false
        end
      end

      def new_session
        @messages = []
        @input = ""
        @loading = false
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
        @messages.flat_map do |msg|
          role_style = if msg[:role] == "user"
            tui.style(fg: "green", modifiers: [:bold])
          else
            tui.style(fg: "cyan", modifiers: [:bold])
          end

          label = (msg[:role] == "user") ? "You" : "Claude"

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

        @messages << {role: "user", content: text}
        @input = ""
        @loading = true

        Thread.new do
          @client ||= LLM::Client.new
          response = @client.chat(@messages)
          @messages << {role: "assistant", content: response}
        rescue => e
          @messages << {role: "assistant", content: "Error: #{e.message}"}
        ensure
          @loading = false
        end
      end

      def printable_char?(event)
        return false if event.modifiers&.any?

        event.code.length == 1 && event.code.match?(/[[:print:]]/)
      end
    end
  end
end
