# frozen_string_literal: true

module TUI
  module Decorators
    # Renders edit_file tool calls and responses.
    # Calls show the file path in the header line for immediate visibility.
    # Responses use the CRUD Update color (light_yellow) to flag modifications.
    class EditDecorator < BaseDecorator
      include FileCallBehavior

      ICON = "\u270F\uFE0F" # pencil

      def icon
        ICON
      end

      def response_color
        "light_yellow"
      end
    end
  end
end
