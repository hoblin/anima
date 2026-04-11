# frozen_string_literal: true

# Decorates user_message records for display in the TUI.
# Basic mode returns role and content. Verbose mode adds a timestamp.
# Debug mode adds token count (exact when counted, estimated when not).
class UserMessageDecorator < MessageDecorator
  # @return [Hash] structured user message data `{role: :user, content: String}`
  def render_basic
    {role: :user, content: content}
  end

  # @return [Hash] structured user message with nanosecond timestamp
  def render_verbose
    {role: :user, content: content, timestamp: timestamp}
  end

  # @return [Hash] verbose output plus token count for debugging
  def render_debug
    render_verbose.merge(token_info)
  end

  # @return [String] user message for the analytical brain, middle-truncated
  #   if very long (preserves intent at start and conclusion at end)
  def render_brain
    "User: #{truncate_middle(content)}"
  end

  # @return [String] transcript line for Mneme's eviction/context zones
  def render_mneme
    "message #{id} User: #{content}"
  end
end
