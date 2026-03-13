# frozen_string_literal: true

# Decorates user_message events for display in the TUI.
# Basic mode returns role and content. Verbose mode adds a timestamp.
class UserMessageDecorator < EventDecorator
  # @return [Hash] structured user message data
  #   `{role: :user, content: String}`
  def render_basic
    {role: :user, content: content}
  end

  # @return [Hash] structured user message with nanosecond timestamp
  #   `{role: :user, content: String, timestamp: Integer|nil}`
  def render_verbose
    {role: :user, content: content, timestamp: timestamp}
  end
end
