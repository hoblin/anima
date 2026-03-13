# frozen_string_literal: true

# Decorates agent_message events for display in the TUI.
# Basic mode returns role and content. Verbose mode adds a timestamp.
class AgentMessageDecorator < EventDecorator
  # @return [Hash] structured agent message data
  #   `{role: :assistant, content: String}`
  def render_basic
    {role: :assistant, content: content}
  end

  # @return [Hash] structured agent message with nanosecond timestamp
  #   `{role: :assistant, content: String, timestamp: Integer|nil}`
  def render_verbose
    {role: :assistant, content: content, timestamp: timestamp}
  end
end
