# frozen_string_literal: true

# Decorates agent_message events for display in the TUI.
# Basic mode shows the response with an "Anima:" prefix.
# Verbose mode adds a timestamp.
class AgentMessageDecorator < EventDecorator
  # @return [Array<String>] the agent message prefixed with "Anima:"
  def render_basic
    ["Anima: #{content}"]
  end

  # @return [Array<String>] timestamped agent message
  def render_verbose
    ["[#{format_timestamp}] Anima: #{content}"]
  end
end
