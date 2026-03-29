# frozen_string_literal: true

module TUI
  module Decorators
    # Renders write_file tool calls and responses.
    # Calls show the file path with a memo icon in the unified tool color.
    # Responses use the CRUD Create color (light_green) to signal new content.
    class WriteDecorator < BaseDecorator
      ICON = "\u{1F4DD}" # memo

      def icon
        ICON
      end

      def response_color
        "light_green"
      end
    end
  end
end
