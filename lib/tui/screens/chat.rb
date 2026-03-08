# frozen_string_literal: true

module TUI
  module Screens
    class Chat
      def render(frame, area, tui)
        widget = tui.paragraph(
          text: "Welcome to Anima. Chat will appear here.",
          alignment: :center,
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
    end
  end
end
