# frozen_string_literal: true

module TUI
  module Decorators
    # Renders read_file tool calls and responses.
    # Calls show the file path in the header line for immediate visibility.
    # Responses use the CRUD Read color (light_blue) for informational content.
    class ReadDecorator < BaseDecorator
      include FileCallBehavior

      ICON = "\u{1F4C4}" # page facing up

      def icon
        ICON
      end

      def response_color
        Settings.theme_tool_read_color
      end
    end
  end
end
