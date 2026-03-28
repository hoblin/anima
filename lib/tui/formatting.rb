# frozen_string_literal: true

module TUI
  # Shared formatting helpers for timestamps and token counts.
  # Used by both the Chat screen and client-side decorators
  # to avoid duplicating display logic.
  module Formatting
    # Formats a token count for display, with tilde prefix for estimates.
    # @param tokens [Integer, nil] token count
    # @param estimated [Boolean] whether the count is an estimate
    # @return [String] formatted label, e.g. "[42 tok]" or "[~28 tok]"
    def format_token_label(tokens, estimated)
      return "" unless tokens

      label = estimated ? "~#{tokens}" : tokens.to_s
      "[#{label} tok]"
    end

    # Returns a semantic color for token count display.
    # Visually flags expensive messages so runaway tool calls or bloated
    # responses jump out immediately in debug mode.
    #
    # @param tokens [Integer] token count
    # @return [String, Integer] named color or 256-color index
    def token_count_color(tokens)
      return "dark_gray" if tokens < 1_000
      return "white" if tokens < 3_000
      return "yellow" if tokens < 10_000
      return 208 if tokens < 20_000 # orange (256-color)

      "red"
    end

    # Converts nanosecond-precision timestamp to human-readable HH:MM:SS.
    # @param ns [Integer, nil] nanosecond timestamp
    # @return [String] formatted time, or "--:--:--" when nil
    def format_ns_timestamp(ns)
      return "--:--:--" unless ns

      Time.at(ns / 1_000_000_000.0).strftime("%H:%M:%S")
    end
  end
end
