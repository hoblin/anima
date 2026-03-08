# frozen_string_literal: true

require_relative "screens/chat"
require_relative "screens/settings"
require_relative "screens/anthropic"

module TUI
  class App
    SCREENS = %i[chat settings anthropic].freeze

    COMMAND_KEYS = {
      "n" => :new_session,
      "s" => :settings,
      "a" => :anthropic,
      "q" => :quit
    }.freeze

    MENU_LABELS = COMMAND_KEYS.map { |key, action| "[#{key}] #{action.capitalize}" }.freeze

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
      if @command_mode
        render_menu(frame, area, tui)
      else
        render_info(frame, area, tui)
      end
    end

    def render_menu(frame, area, tui)
      menu = tui.list(
        items: MENU_LABELS,
        block: tui.block(
          title: "Command",
          borders: [:all],
          border_type: :rounded,
          border_style: {fg: "yellow"}
        )
      )
      frame.render_widget(menu, area)
    end

    def render_info(frame, area, tui)
      info_text = tui.line(spans: [
        tui.span(content: "Anima v#{Anima::VERSION}", style: tui.style(fg: "white"))
      ])
      hint_text = tui.line(spans: [
        tui.span(content: "Ctrl+a", style: tui.style(fg: "cyan", modifiers: [:bold])),
        tui.span(content: " command mode", style: tui.style(fg: "dark_gray"))
      ])

      info = tui.paragraph(
        text: [info_text, hint_text],
        block: tui.block(
          title: "Info",
          borders: [:all],
          border_type: :rounded,
          border_style: {fg: "white"}
        )
      )
      frame.render_widget(info, area)
    end

    def render_status_bar(frame, area, tui)
      mode_span = if @command_mode
        tui.span(content: " COMMAND ", style: tui.style(fg: "black", bg: "yellow", modifiers: [:bold]))
      elsif chat_loading?
        tui.span(content: " THINKING ", style: tui.style(fg: "black", bg: "magenta", modifiers: [:bold]))
      else
        tui.span(content: " NORMAL ", style: tui.style(fg: "black", bg: "cyan", modifiers: [:bold]))
      end

      widget = tui.paragraph(text: tui.line(spans: [mode_span]))
      frame.render_widget(widget, area)
    end

    def chat_loading?
      @screens[:chat].loading?
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
      when :new_session
        @screens[:chat].new_session
        @current_screen = :chat
        nil
      when :settings, :anthropic
        @current_screen = action
        nil
      end
    end

    def handle_normal_mode(event)
      return nil unless event.key?

      if ctrl_a?(event)
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

    def ctrl_a?(event)
      event.code == "a" && event.modifiers&.include?("ctrl")
    end
  end
end
