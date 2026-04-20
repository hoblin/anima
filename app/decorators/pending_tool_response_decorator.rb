# frozen_string_literal: true

# Decorates a +tool_response+ {PendingMessage} — a tool result waiting in
# the mailbox before the drain pairs it with its tool_call and feeds the
# next LLM turn. Mirrors {ToolResponseDecorator}: hidden in basic
# (aggregated by the tool counter), structured tool output in verbose,
# full untruncated content in debug — all dimmed via
# +status: "pending"+.
class PendingToolResponseDecorator < PendingMessageDecorator
  # @return [nil] tool responses are hidden in basic mode
  def render_basic
    nil
  end

  # @return [Hash] truncated tool response payload tagged as pending
  def render_verbose
    {
      role: :tool_response,
      tool: source_name,
      content: truncate_lines(content, max_lines: 3),
      success: success != false,
      tool_use_id: tool_use_id,
      status: "pending"
    }
  end

  # @return [Hash] full tool response payload tagged as pending
  def render_debug
    {
      role: :tool_response,
      tool: source_name,
      content: content,
      success: success != false,
      tool_use_id: tool_use_id,
      status: "pending"
    }
  end

  # @return [String] Melete transcript line
  def render_melete
    "tool_response #{tool_use_id} (pending): #{truncate_middle(content)}"
  end

  # @return [String] Mneme transcript line
  def render_mneme
    "tool_response #{tool_use_id} (pending): #{truncate_middle(content)}"
  end
end
