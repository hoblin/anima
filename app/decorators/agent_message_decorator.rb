# frozen_string_literal: true

# Renders agent (LLM) response messages.
# In basic mode, displays the message with an "Anima" label prefix.
class AgentMessageDecorator < EventDecorator
  LABEL = "Anima"

  def label = LABEL

  def role = :assistant

  # @return [Array<String>] message lines prefixed with "Anima: " on the first line
  def render_basic
    render_labeled_content
  end
end
