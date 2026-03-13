# frozen_string_literal: true

# Decorates tool_call events for display in the TUI.
# Hidden in basic mode — tool activity is represented by the
# aggregated tool counter instead. Verbose mode shows tool name
# and a compact preview of the input arguments.
class ToolCallDecorator < EventDecorator
  # @return [nil] tool calls are hidden in basic mode
  def render_basic
    nil
  end

  # Shows tool name as header with truncated input preview.
  # @return [Array<String>] header line + indented input lines
  def render_verbose
    lines = ["\u{1F527} #{payload["tool_name"]}"]
    formatted_input.split("\n").each { |line| lines << "  #{line}" }
    lines
  end

  private

  # Formats tool input for display, with tool-specific formatting for
  # known tools and generic JSON fallback for others.
  # @return [String] formatted input preview
  def formatted_input
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
