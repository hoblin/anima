# frozen_string_literal: true

module TUI
  module Decorators
    # Renders web_get tool calls and responses.
    # Calls show the URL with a globe icon in the unified tool color.
    # Responses use the CRUD Read color (light_blue) for fetched content.
    class WebGetDecorator < BaseDecorator
      ICON = "\u{1F310}" # globe with meridians

      def icon
        ICON
      end

      def response_color
        "light_blue"
      end
    end
  end
end
