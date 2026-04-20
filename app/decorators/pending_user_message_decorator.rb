# frozen_string_literal: true

# Decorates a +user_message+ {PendingMessage} — the user's input as it
# sits in the mailbox between submission and promotion. Mirrors
# {UserMessageDecorator}'s shape, with +status: "pending"+ added so the
# TUI dims the entry.
class PendingUserMessageDecorator < PendingMessageDecorator
  # @return [Hash] dimmed user message payload
  def render_basic
    {role: :user, content: content, status: "pending"}
  end

  # @return [String] Melete transcript line
  def render_melete
    "User (pending): #{truncate_middle(content)}"
  end

  # @return [String] Mneme transcript line
  def render_mneme
    "User (pending): #{truncate_middle(content)}"
  end
end
