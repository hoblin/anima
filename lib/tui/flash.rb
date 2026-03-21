# frozen_string_literal: true

module TUI
  # Ephemeral notification system for the TUI, modeled after Rails flash
  # messages. Notifications appear at the top of the chat pane and
  # auto-dismiss after a configurable timeout or on any keypress.
  #
  # Reusable beyond Bounce Back — useful for connection status changes,
  # background task notifications, and any transient user feedback that
  # doesn't belong in the chat stream.
  #
  # @example Adding a flash
  #   flash = TUI::Flash.new
  #   flash.error("Message not delivered: API token not configured")
  #   flash.warning("Rate limited, retry in 30s")
  #   flash.info("Reconnected to server")
  #
  # @example Rendering
  #   flash.render(frame, area, tui) unless flash.empty?
  #
  # @example Dismissing
  #   flash.dismiss!
  class Flash
    # @return [Float] seconds before auto-dismiss (0 = sticky)
    AUTO_DISMISS_SECONDS = 5.0

    Entry = Struct.new(:message, :level, :created_at, keyword_init: true)

    LEVELS = {error: "red", warning: "yellow", info: "blue"}.freeze

    def initialize
      @entries = []
    end

    # @param message [String]
    def error(message)
      push(message, :error)
    end

    # @param message [String]
    def warning(message)
      push(message, :warning)
    end

    # @param message [String]
    def info(message)
      push(message, :info)
    end

    # Removes expired entries and returns true if any remain.
    def any?
      expire!
      @entries.any?
    end

    # @return [Boolean]
    def empty?
      !any?
    end

    # Removes all entries immediately (e.g. on keypress).
    def dismiss!
      @entries.clear
    end

    # Renders the flash overlay at the top of the given area.
    # Returns the height consumed so the caller can adjust layout.
    #
    # @param frame [RatatuiRuby::Frame]
    # @param area [RatatuiRuby::Rect] full chat area (flash renders at top)
    # @param tui [RatatuiRuby::TUI]
    # @return [Integer] number of rows consumed by the flash
    def render(frame, area, tui)
      expire!
      return 0 if @entries.empty?

      lines = @entries.map { |entry| build_line(entry, tui) }
      height = [lines.size + 2, area.height / 3].min # +2 for border

      flash_area, _ = tui.split(
        area,
        direction: :vertical,
        constraints: [
          tui.constraint_length(height),
          tui.constraint_fill(1)
        ]
      )

      paragraph = tui.paragraph(
        text: lines,
        block: tui.block(
          borders: [:bottom],
          border_style: {fg: border_color}
        )
      )

      frame.render_widget(paragraph, flash_area)
      height
    end

    private

    def push(message, level)
      @entries << Entry.new(message: message, level: level, created_at: monotonic_now)
    end

    def expire!
      now = monotonic_now
      @entries.reject! { |entry| now - entry.created_at > AUTO_DISMISS_SECONDS }
    end

    def build_line(entry, tui)
      color = LEVELS.fetch(entry.level, "white")
      icon = (entry.level == :info) ? "\u2139\uFE0F " : "\u26A0\uFE0F "
      tui.line(spans: [
        tui.span(content: " #{icon}", style: tui.style(fg: color)),
        tui.span(content: entry.message, style: tui.style(fg: color))
      ])
    end

    def border_color
      return "red" if @entries.any? { |e| e.level == :error }
      return "yellow" if @entries.any? { |e| e.level == :warning }
      "blue"
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
