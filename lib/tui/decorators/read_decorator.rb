# frozen_string_literal: true

module TUI
  module Decorators
    # Renders read tool calls and responses.
    # Calls show the file path with a page icon in the unified tool color.
    # Responses use the CRUD Read color (light_blue) for informational content.
    class ReadDecorator < BaseDecorator
      ICON = "\u{1F4C4}" # page facing up

      def icon
        ICON
      end

      def response_color
        "light_blue"
      end
    end
  end
end
