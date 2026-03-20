# frozen_string_literal: true

module TUI
  module Decorators
    # Renders bash tool calls and responses.
    # Calls show the shell command with a terminal icon.
    # Responses use green for success, red for failure.
    class BashDecorator < BaseDecorator
      ICON = "\u{1F4BB}" # laptop / terminal

      def icon
        ICON
      end

      def response_color
        (data["success"] == false) ? "red" : "green"
      end
    end
  end
end
