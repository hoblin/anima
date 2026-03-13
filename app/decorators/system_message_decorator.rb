# frozen_string_literal: true

# Decorates system_message events for display in the TUI.
# Hidden in basic mode. Verbose mode shows timestamped system info.
class SystemMessageDecorator < EventDecorator
  # @return [nil] system messages are hidden in basic mode
  def render_basic
    nil
  end

  # @return [Array<String>] timestamped system message
  def render_verbose
    ["[#{format_timestamp}] [system] #{content}"]
  end
end
