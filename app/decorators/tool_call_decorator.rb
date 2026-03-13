# frozen_string_literal: true

# Decorates tool_call events for display in the TUI.
# Hidden in basic mode — tool activity is represented by the
# aggregated tool counter instead. Verbose mode returns tool name
# and a formatted preview of the input arguments.
class ToolCallDecorator < EventDecorator
  # @return [nil] tool calls are hidden in basic mode
  def render_basic
    nil
  end

  # @return [Hash] structured tool call data
  #   `{role: :tool_call, tool: String, input: String, timestamp: Integer|nil}`
  def render_verbose
    {role: :tool_call, tool: payload["tool_name"], input: format_input, timestamp: timestamp}
  end

  private

  # Formats tool input for display, with tool-specific formatting for
  # known tools and generic JSON fallback for others.
  # @return [String] formatted input preview
  def format_input
    input = payload["tool_input"]
    case payload["tool_name"]
    when "bash"
      "$ #{input&.dig("command")}"
    when "web_get"
      "GET #{input&.dig("url")}"
    else
      truncate_lines(input.to_json, max_lines: 2)
    end
  end
end
