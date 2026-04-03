# frozen_string_literal: true

require_relative "settings"

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
    Entry = Struct.new(:message, :level, :created_at, keyword_init: true)

    LEVEL_ICONS = {error: " \u2718 ", warning: " \u26A0 ", info: " \u2139 "}.freeze

    # Builds level styles from current theme settings.
    # Called per-render so hot-reloaded theme changes take effect immediately.
    def self.level_styles
      {
        error: {fg: Settings.flash_error_fg, bg: Settings.flash_error_bg},
        warning: {fg: Settings.flash_warning_fg, bg: Settings.flash_warning_bg},
        info: {fg: Settings.flash_info_fg, bg: Settings.flash_info_bg}
      }
    end

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

      height = [@entries.size, area.height / Settings.flash_max_height_fraction].min

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
      @entries.reject! { |entry| now - entry.created_at > Settings.flash_auto_dismiss_seconds }
    end

    def row_rect(area, index, tui)
      rows = (0...area.height).map { tui.constraint_length(1) }
      chunks = tui.split(area, direction: :vertical, constraints: rows)
      chunks[index]
    end

    def render_entry(frame, area, entry, tui)
      styles = self.class.level_styles
      config = styles.fetch(entry.level, styles[:info])
      icon = LEVEL_ICONS.fetch(entry.level, LEVEL_ICONS[:info])
      style = tui.style(fg: config[:fg], bg: config[:bg], modifiers: [:bold])

      text = "#{icon}#{entry.message} "
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
