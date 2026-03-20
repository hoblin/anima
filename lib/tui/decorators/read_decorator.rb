# frozen_string_literal: true

module TUI
  module Decorators
    # Renders read tool calls and responses.
    # Calls show the file path with a page icon.
    # Responses show file content in dim text.
    class ReadDecorator < BaseDecorator
      ICON = "\u{1F4C4}" # page facing up

      def icon
        ICON
      end

      def color
        "cyan"
      end

      def response_color
        "dark_gray"
      end
    end
  end
end
