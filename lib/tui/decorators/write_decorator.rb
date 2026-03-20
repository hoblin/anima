# frozen_string_literal: true

module TUI
  module Decorators
    # Renders write tool calls and responses.
    # Calls show the file path with a memo icon.
    class WriteDecorator < BaseDecorator
      ICON = "\u{1F4DD}" # memo

      def icon
        ICON
      end

      def color
        "yellow"
      end
    end
  end
end
