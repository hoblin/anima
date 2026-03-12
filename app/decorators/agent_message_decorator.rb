# frozen_string_literal: true

# Decorates agent_message events for display in the TUI.
# In basic mode, shows the agent's response with an "Anima:" prefix.
class AgentMessageDecorator < EventDecorator
  # @return [Array<String>] the agent message prefixed with "Anima:"
  def render_basic
    ["Anima: #{content}"]
  end
end
