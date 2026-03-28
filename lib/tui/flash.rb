# frozen_string_literal: true

module TUI
  # Ephemeral notification system for the TUI, modeled after Rails flash
  # messages. Notifications render as a colored bar at the top of the
  # chat pane and auto-dismiss after a configurable timeout or on any
  # keypress.
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
  # @example Rendering (returns height consumed)
  #   flash_height = flash.render(frame, area, tui)
  #
  # @example Dismissing
  #   flash.dismiss!
  class Flash
    AUTO_DISMISS_SECONDS = 20.0

    # Flash area occupies at most 1/3 of the chat pane height.
    MAX_HEIGHT_FRACTION = 3

    Entry = Struct.new(:message, :level, :created_at, keyword_init: true)

    LEVEL_STYLES = {
      error: {fg: "white", bg: "red", icon: " \u2718 "},
      warning: {fg: "black", bg: "yellow", icon: " \u26A0 "},
      info: {fg: "white", bg: "blue", icon: " \u2139 "}
    }.freeze

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

    # Renders flash entries as colored bars at the top of the given area.
    # Returns the height consumed so the caller can adjust layout.
    #
    # @param frame [RatatuiRuby::Frame]
    # @param area [RatatuiRuby::Rect] full chat area (flash renders at top)
    # @param tui [RatatuiRuby::TUI]
    # @return [Integer] number of rows consumed
    def render(frame, area, tui)
      expire!
      return 0 if @entries.empty?

      height = [@entries.size, area.height / MAX_HEIGHT_FRACTION].min

      flash_area, _ = tui.split(
        area,
        direction: :vertical,
        constraints: [
          tui.constraint_length(height),
          tui.constraint_fill(1)
        ]
      )

      @entries.each_with_index do |entry, index|
        break if index >= height

        row_area = row_rect(flash_area, index, tui)
        render_entry(frame, row_area, entry, tui)
      end

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

    def row_rect(area, index, tui)
      rows = (0...area.height).map { tui.constraint_length(1) }
      chunks = tui.split(area, direction: :vertical, constraints: rows)
      chunks[index]
    end

    def render_entry(frame, area, entry, tui)
      config = LEVEL_STYLES.fetch(entry.level, LEVEL_STYLES[:info])
      style = tui.style(fg: config[:fg], bg: config[:bg], modifiers: [:bold])

      text = "#{config[:icon]}#{entry.message} "
      # Pad to full width so background color fills the entire row
      padded = text.ljust(area.width)

      line = tui.line(spans: [tui.span(content: padded, style: style)])
      widget = tui.paragraph(text: [line])
      frame.render_widget(widget, area)
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
