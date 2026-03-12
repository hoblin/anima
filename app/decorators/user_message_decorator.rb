# frozen_string_literal: true

# Decorates user_message events for display in the TUI.
# In basic mode, shows the user's message with a "You:" prefix.
class UserMessageDecorator < EventDecorator
  # @return [Array<String>] the user message prefixed with "You:"
  def render_basic
    ["You: #{content}"]
  end
end
