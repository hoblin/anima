# frozen_string_literal: true

module TUI
  module Decorators
    # Renders list_files tool calls and responses.
    # Calls show the search path/pattern with a folder icon.
    class ListFilesDecorator < BaseDecorator
      ICON = "\u{1F4C1}" # file folder

      def icon
        ICON
      end

      def color
        "cyan"
      end

      def response_color
        "dark_gray"
      end
    end
  end
end
