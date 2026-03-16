# frozen_string_literal: true

# Decorates agent_message events for display in the TUI.
# Basic mode returns role and content. Verbose mode adds a timestamp.
# Debug mode adds token count (exact when counted, estimated when not).
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

  # @return [Hash] verbose output plus token count for debugging
  #   `{role: :assistant, content: String, timestamp: Integer|nil, tokens: Integer, estimated: Boolean}`
  def render_debug
    render_verbose.merge(token_info)
  end

  # @return [String] agent message for the analytical brain, middle-truncated
  #   if very long (preserves opening context and final conclusion)
  def render_brain
    "Assistant: #{truncate_middle(content)}"
  end
end
