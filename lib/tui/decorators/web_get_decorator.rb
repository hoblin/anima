# frozen_string_literal: true

module TUI
  module Decorators
    # Renders web_get tool calls and responses.
    # Calls show the URL with a globe icon.
    class WebGetDecorator < BaseDecorator
      ICON = "\u{1F310}" # globe with meridians

      def icon
        ICON
      end

      def color
        "blue"
      end
    end
  end
end
