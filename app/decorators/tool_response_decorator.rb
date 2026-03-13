# frozen_string_literal: true

# Decorates tool_response events for display in the TUI.
# Hidden in basic mode — tool activity is represented by the
# aggregated tool counter instead. Verbose mode returns truncated
# output with a success/failure indicator. Debug mode shows full
# untruncated output with tool_use_id and estimated token count.
class ToolResponseDecorator < EventDecorator
  # @return [nil] tool responses are hidden in basic mode
  def render_basic
    nil
  end

  # @return [Hash] structured tool response data
  #   `{role: :tool_response, content: String, success: Boolean, timestamp: Integer|nil}`
  def render_verbose
    {
      role: :tool_response,
      content: truncate_lines(content, max_lines: 3),
      success: payload["success"] != false,
      timestamp: timestamp
    }
  end

  # @return [Hash] full tool response data with untruncated content, tool_use_id, and token estimate
  #   `{role: :tool_response, content: String, success: Boolean, tool_use_id: String|nil,
  #     timestamp: Integer|nil, tokens: Integer, estimated: Boolean}`
  def render_debug
    {
      role: :tool_response,
      content: content,
      success: payload["success"] != false,
      tool_use_id: payload["tool_use_id"],
      timestamp: timestamp
    }.merge(token_info)
  end
end
