# frozen_string_literal: true

# Decorates tool_response events for display in the TUI.
# Hidden in basic mode — tool activity is represented by the
# aggregated tool counter instead. Verbose mode shows truncated
# output, prefixed with a return arrow (or error indicator on failure).
class ToolResponseDecorator < EventDecorator
  # @return [nil] tool responses are hidden in basic mode
  def render_basic
    nil
  end

  # Shows truncated tool output, indented under its tool call.
  # Failed tools get an error indicator instead of the return arrow.
  # @return [Array<String>] indented output lines
  def render_verbose
    lines = truncate_lines(content, max_lines: 3).split("\n")
    prefix = (payload["success"] == false) ? "#{ERROR_ICON} " : "#{RETURN_ARROW} "
    ["  #{prefix}#{lines.first}"].concat(lines.drop(1).map { |line| "    #{line}" })
  end
end
