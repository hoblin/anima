# frozen_string_literal: true

module TUI
  module Decorators
    # Renders edit_file tool calls and responses.
    # Calls show the file path with a pencil icon.
    class EditFileDecorator < BaseDecorator
      ICON = "\u270F\uFE0F" # pencil

      def icon
        ICON
      end

      def color
        "yellow"
      end
    end
  end
end
