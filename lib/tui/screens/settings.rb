# frozen_string_literal: true

module TUI
  module Screens
    class Settings
      MENU_ITEMS = [
        "General",
        "Appearance",
        "Keybindings"
      ].freeze

      def initialize
        @list_state = nil
      end

      def render(frame, area, tui)
        @list_state ||= tui.list_state(0)

        list = tui.list(
          items: MENU_ITEMS,
          highlight_style: {fg: "yellow", bold: true},
          highlight_symbol: "> ",
          block: tui.block(
            title: "Settings",
            titles: [
              {content: "↑/↓ navigate • Esc back", position: :bottom, alignment: :center}
            ],
            borders: [:all],
            border_type: :rounded,
            border_style: {fg: "green"}
          )
        )
        frame.render_stateful_widget(list, area, @list_state)
      end

      def handle_event(event)
        return false unless @list_state

        if event.down? || event.j?
          @list_state.select_next
          true
        elsif event.up? || event.k?
          @list_state.select_previous
          true
        else
          false
        end
      end
    end
  end
end
