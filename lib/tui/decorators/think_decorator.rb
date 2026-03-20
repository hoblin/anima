# frozen_string_literal: true

module TUI
  module Decorators
    # Renders think tool events — the agent's inner reasoning.
    # "aloud" thoughts use yellow (narration for the user), "inner"
    # thoughts use dark_gray (dimmed to signal internality).
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
        aloud = data["visibility"] == "aloud"
        fg = aloud ? "yellow" : "dark_gray"
        style = tui.style(fg: fg)
        ts = data["timestamp"]

        meta = []
        meta << "[#{format_ns_timestamp(ts)}]" if ts
        header = meta.empty? ? icon : "#{meta.join(" ")} #{icon}"

        content_lines = data["content"].to_s.split("\n", -1)
        lines = [tui.line(spans: [tui.span(content: "#{header} #{content_lines.first}", style: style)])]
        content_lines.drop(1).each { |line| lines << tui.line(spans: [tui.span(content: "  #{line}", style: style)]) }
        lines
      end
    end
  end
end
