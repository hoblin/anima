# frozen_string_literal: true

module TUI
  module Screens
    class Anthropic
      def render(frame, area, tui)
        widget = tui.paragraph(
          text: "Anthropic account connection will be configured here.",
          alignment: :center,
          wrap: true,
          block: tui.block(
            title: "Anthropic Connection",
            titles: [
              {content: "Esc back", position: :bottom, alignment: :center}
            ],
            borders: [:all],
            border_type: :rounded,
            border_style: {fg: "magenta"}
          )
        )
        frame.render_widget(widget, area)
      end
    end
  end
end
