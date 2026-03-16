# frozen_string_literal: true

# Decorates tool_response events for display in the TUI.
# Hidden in basic mode — tool activity is represented by the
# aggregated tool counter instead. Verbose mode returns truncated
# output with a success/failure indicator. Debug mode shows full
# untruncated output with tool_use_id and estimated token count.
#
# Think tool responses ("OK") are hidden in basic and verbose modes
# because the value is in the tool_call (the thoughts), not the response.
class ToolResponseDecorator < EventDecorator
  THINK_TOOL = "think"

  # @return [nil] tool responses are hidden in basic mode
  def render_basic
    nil
  end

  # Think responses are hidden in verbose mode — the "OK" adds no information.
  # @return [Hash, nil] structured tool response data, nil for think responses
  def render_verbose
    return if think?

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

  # Think responses ("OK") are noise — excluded from the brain's transcript.
  # Other tool responses are compressed to success/failure indicators only.
  # @return [String, nil] ✅ or ❌ indicator, nil for think responses
  def render_brain
    return if think?

    (payload["success"] != false) ? "\u2705" : "\u274C"
  end

  private

  def think?
    payload["tool_name"] == THINK_TOOL
  end
end
