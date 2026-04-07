# frozen_string_literal: true

# Decorates system_message records for display in the TUI.
# Hidden in basic mode. Verbose and debug modes return timestamped system info.
class SystemMessageDecorator < MessageDecorator
  # @return [nil] system messages are hidden in basic mode
  def render_basic
    nil
  end

  # @return [Hash] structured system message data
  #   `{role: :system, content: String, timestamp: Integer|nil}`
  def render_verbose
    {role: :system, content: content, timestamp: timestamp}
  end

  # @return [Hash] same as verbose — system messages have no additional debug data
  def render_debug
    render_verbose
  end

  # @return [String] transcript line for Mneme's eviction/context zones
  def render_mneme
    "message #{id} System: #{content}"
  end
end
