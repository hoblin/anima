# frozen_string_literal: true

# Decorates system_message events for display in the TUI.
# Hidden in basic mode. Verbose mode returns timestamped system info.
class SystemMessageDecorator < EventDecorator
  # @return [nil] system messages are hidden in basic mode
  def render_basic
    nil
  end

  # @return [Hash] structured system message data
  #   `{role: :system, content: String, timestamp: Integer|nil}`
  def render_verbose
    {role: :system, content: content, timestamp: timestamp}
  end
end
