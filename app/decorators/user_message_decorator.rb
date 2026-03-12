# frozen_string_literal: true

# Renders user-submitted messages.
# In basic mode, displays the message with a "You" label prefix.
class UserMessageDecorator < EventDecorator
  LABEL = "You"

  def label = LABEL

  def role = :user

  # @return [Array<String>] message lines prefixed with "You: " on the first line
  def render_basic
    render_labeled_content
  end
end
