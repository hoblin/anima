# frozen_string_literal: true

# Decorates user_message events for display in the TUI.
# Basic mode shows the message with a "You:" prefix.
# Verbose mode adds a timestamp.
class UserMessageDecorator < EventDecorator
  # @return [Array<String>] the user message prefixed with "You:"
  def render_basic
    ["You: #{content}"]
  end

  # @return [Array<String>] timestamped user message
  def render_verbose
    ["[#{format_timestamp}] You: #{content}"]
  end
end
