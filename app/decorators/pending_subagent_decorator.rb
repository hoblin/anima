# frozen_string_literal: true

# Decorates a +subagent+ {PendingMessage} — a sub-agent's reply that
# landed on the parent's mailbox via {SubagentMessageRouter}. Promotes
# into a phantom +from_<nickname>+ tool_call/tool_response pair, but
# while pending it surfaces as a labeled inbound delivery so the user
# sees which sub-agent is talking to her.
#
# Hidden in basic (matches the promoted tool pair, which is hidden in
# basic). Visible from verbose with a +[from <nickname>]+ badge.
class PendingSubagentDecorator < PendingMessageDecorator
  # @return [nil] sub-agent deliveries are hidden in basic mode
  def render_basic
    nil
  end

  # @return [Hash] dimmed sub-agent delivery payload
  def render_verbose
    {
      role: :pending_subagent,
      source: source_name,
      content: truncate_lines(content, max_lines: 3),
      status: "pending"
    }
  end

  # @return [Hash] full sub-agent delivery payload
  def render_debug
    {
      role: :pending_subagent,
      source: source_name,
      content: content,
      status: "pending"
    }
  end

  # @return [String] Melete transcript line
  def render_melete
    "Sub-agent #{source_name} (pending): #{truncate_middle(content)}"
  end

  # @return [String] Mneme transcript line
  def render_mneme
    "Sub-agent #{source_name} (pending): #{truncate_middle(content)}"
  end
end
