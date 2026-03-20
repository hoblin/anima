# frozen_string_literal: true

module TUI
  module Decorators
    # Renders search_files tool calls and responses.
    # Calls show the search pattern with a magnifying glass icon.
    class SearchFilesDecorator < BaseDecorator
      ICON = "\u{1F50D}" # magnifying glass

      def icon
        ICON
      end

      def color
        "magenta"
      end

      def response_color
        "dark_gray"
      end
    end
  end
end
