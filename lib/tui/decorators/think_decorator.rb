# frozen_string_literal: true

module TUI
  module Decorators
    # Renders think tool events — the agent's inner reasoning.
    # Both "aloud" and "inner" thoughts use grey (dark_gray) to visually
    # de-emphasize reasoning content vs. actual conversation output.
    class ThinkDecorator < BaseDecorator
      THOUGHT_BUBBLE = "\u{1F4AD}" # thought balloon

      def icon
        THOUGHT_BUBBLE
      end

      # Think events always dispatch here via BaseDecorator#render.
      #
      # @param tui [RatatuiRuby] TUI rendering API
      # @return [Array<RatatuiRuby::Widgets::Line>]
      def render_think(tui)
        style = tui.style(fg: "dark_gray")
        ts = data["timestamp"]

        meta = []
        meta << "[#{format_ns_timestamp(ts)}]" if ts
        header = meta.empty? ? icon : "#{meta.join(" ")} #{icon}"

        content_lines = data["content"].to_s.split("\n", -1)
        lines = [tui.line(spans: [tui.span(content: "#{header} #{content_lines.first}", style: style)])]
        content_lines.drop(1).each { |line| lines << tui.line(spans: [tui.span(content: preserve_indentation("  #{line}"), style: style)]) }
        lines
      end
    end
  end
end
