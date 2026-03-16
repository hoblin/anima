# frozen_string_literal: true

# Decorates user_message events for display in the TUI.
# Basic mode returns role and content. Verbose mode adds a timestamp.
# Debug mode adds token count (exact when counted, estimated when not).
# Pending messages include `status: "pending"` so the TUI renders them
# with a visual indicator (dimmed, clock icon).
class UserMessageDecorator < EventDecorator
  # @return [Hash] structured user message data
  #   `{role: :user, content: String}` or with `status: "pending"` when queued
  def render_basic
    base = {role: :user, content: content}
    base[:status] = "pending" if pending?
    base
  end

  # @return [Hash] structured user message with nanosecond timestamp
  def render_verbose
    base = {role: :user, content: content, timestamp: timestamp}
    base[:status] = "pending" if pending?
    base
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

  private

  # @return [Boolean] true when this message is queued but not yet sent to LLM
  def pending?
    payload["status"] == Event::PENDING_STATUS
  end
end
