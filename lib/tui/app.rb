# frozen_string_literal: true

require_relative "screens/chat"
require_relative "screens/settings"
require_relative "screens/anthropic"

module TUI
  class App
    SCREENS = %i[chat settings anthropic].freeze

    COMMAND_KEYS = {
      "s" => :settings,
      "a" => :anthropic,
      "q" => :quit
    }.freeze

    SIDEBAR_WIDTH = 28

    attr_reader :current_screen, :command_mode

    def initialize
      @current_screen = :chat
      @command_mode = false
      @screens = {
        chat: Screens::Chat.new,
        settings: Screens::Settings.new,
        anthropic: Screens::Anthropic.new
      }
    end

    def run
      RatatuiRuby.run do |tui|
        loop do
          tui.draw { |frame| render(frame, tui) }

          break if handle_event(tui.poll_event) == :quit
        end
      end
    end

    private

    def render(frame, tui)
      main_area, sidebar = tui.split(
        frame.area,
        direction: :horizontal,
        constraints: [
          tui.constraint_fill(1),
          tui.constraint_length(SIDEBAR_WIDTH)
        ]
      )

      content_area, status_bar = tui.split(
        main_area,
        direction: :vertical,
        constraints: [
          tui.constraint_fill(1),
          tui.constraint_length(1)
        ]
      )

      @screens[@current_screen].render(frame, content_area, tui)
      render_sidebar(frame, sidebar, tui)
      render_status_bar(frame, status_bar, tui)
    end

    def render_sidebar(frame, area, tui)
      menu_area, info_area = tui.split(
        area,
        direction: :vertical,
        constraints: [
          tui.constraint_fill(1),
          tui.constraint_length(5)
        ]
      )

      menu_items = SCREENS.map { |s| screen_label(s) }
      menu = tui.list(
        items: menu_items,
        highlight_style: {fg: "cyan", bold: true},
        highlight_symbol: "▸ ",
        selected_index: SCREENS.index(@current_screen),
        block: tui.block(
          title: "Menu",
          borders: [:all],
          border_type: :rounded,
          border_style: {fg: "white"}
        )
      )
      frame.render_widget(menu, menu_area)

      info = tui.paragraph(
        text: "Anima v#{Anima::VERSION}",
        alignment: :center,
        block: tui.block(
          title: "Info",
          borders: [:all],
          border_type: :rounded,
          border_style: {fg: "white"}
        )
      )
      frame.render_widget(info, info_area)
    end

    def render_status_bar(frame, area, tui)
      status_text = if @command_mode
        command_hints = COMMAND_KEYS.map { |key, action| "#{key}:#{action}" }.join("  ")
        tui.line([
          tui.span(" COMMAND ", style: {fg: "black", bg: "yellow", bold: true}),
          tui.span("  #{command_hints}", style: {fg: "yellow"})
        ])
      else
        tui.line([
          tui.span(" NORMAL ", style: {fg: "black", bg: "cyan", bold: true}),
          tui.span("  Ctrl+a: command mode", style: {fg: "white"})
        ])
      end

      widget = tui.paragraph(text: status_text)
      frame.render_widget(widget, area)
    end

    def handle_event(event)
      return nil if event.none?
      return :quit if event.ctrl_c?

      if @command_mode
        handle_command_mode(event)
      else
        handle_normal_mode(event)
      end
    end

    def handle_command_mode(event)
      @command_mode = false

      return nil unless event.key?

      action = COMMAND_KEYS[event.code]
      case action
      when :quit
        :quit
      when :settings, :anthropic
        @current_screen = action
        nil
      end
    end

    def handle_normal_mode(event)
      return nil unless event.key?

      if event.code == "a" && event.modifiers&.include?("ctrl")
        @command_mode = true
        return nil
      end

      if event.esc? && @current_screen != :chat
        @current_screen = :chat
        return nil
      end

      screen = @screens[@current_screen]
      screen.handle_event(event) if screen.respond_to?(:handle_event)
      nil
    end

    def screen_label(screen)
      case screen
      when :chat then "Chat"
      when :settings then "Settings"
      when :anthropic then "Anthropic"
      end
    end
  end
end
