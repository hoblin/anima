# frozen_string_literal: true

module TUI
  module Decorators
    # Renders edit_file tool calls and responses.
    # Calls show the file path with a pencil icon in the unified tool color.
    # Responses use the CRUD Update color (light_yellow) to flag modifications.
    class EditDecorator < BaseDecorator
      ICON = "\u270F\uFE0F" # pencil

      def icon
        ICON
      end

      def response_color
        Settings.theme_tool_update_color
      end
    end
  end
end
