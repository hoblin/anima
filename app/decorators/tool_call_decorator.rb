# frozen_string_literal: true

require "toon"

# Decorates tool_call records for display in the TUI.
# Hidden in basic mode — tool activity is represented by the
# aggregated tool counter instead. Verbose mode returns tool name
# and a formatted preview of the input arguments. Debug mode shows
# full untruncated input with tool_use_id — TOON format for most
# tools, but write tool content preserves actual newlines.
#
# Think tool calls are special: "aloud" thoughts are shown in all
# view modes (with a thought bubble), while "inner" thoughts are
# visible only in verbose and debug modes.
class ToolCallDecorator < MessageDecorator
  THINK_TOOL = "think"

  # In basic mode, only "aloud" think calls are visible.
  # All other tool calls are hidden (represented by the tool counter).
  #
  # @return [Hash, nil] structured think data for aloud thoughts, nil otherwise
  def render_basic
    return unless think?
    return unless aloud?

    {role: :think, content: thoughts, visibility: "aloud"}
  end

  # @return [Hash] structured tool call data
  #   `{role: :tool_call, tool: String, input: String, timestamp: Integer|nil}`
  def render_verbose
    return render_think_verbose if think?

    {role: :tool_call, tool: payload["tool_name"], input: format_input, timestamp: timestamp}
  end

  # @return [Hash] full tool call data with untruncated input and tool_use_id
  #   `{role: :tool_call, tool: String, input: String, tool_use_id: String|nil, timestamp: Integer|nil}`
  def render_debug
    return render_think_debug if think?

    {
      role: :tool_call,
      tool: payload["tool_name"],
      input: format_debug_input,
      tool_use_id: payload["tool_use_id"],
      timestamp: timestamp
    }
  end

  # Think calls get full text — the agent's reasoning IS the signal.
  # Other tool calls show tool name + params (compact JSON).
  # @return [String] transcript line for the analytical brain
  def render_brain
    if think?
      "Think: #{thoughts}"
    else
      "Tool call: #{payload["tool_name"]}(#{tool_input.to_json})"
    end
  end

  private

  def think?
    payload["tool_name"] == THINK_TOOL
  end

  def aloud?
    tool_input.dig("visibility") == "aloud"
  end

  def thoughts
    tool_input.dig("thoughts").to_s
  end

  def tool_input
    payload["tool_input"] || {}
  end

  def visibility
    tool_input.dig("visibility") || "inner"
  end

  # @return [Hash] think event for verbose mode — both inner and aloud visible
  def render_think_verbose
    {role: :think, content: thoughts, visibility: visibility, timestamp: timestamp}
  end

  # @return [Hash] think event for debug mode — full metadata
  def render_think_debug
    {role: :think, content: thoughts, visibility: visibility, tool_use_id: payload["tool_use_id"], timestamp: timestamp}
  end

  # Full tool input for debug mode. Write tool content is shown with
  # preserved newlines instead of TOON-escaping them into literal \n.
  # @return [String] formatted debug input
  def format_debug_input
    input = tool_input
    case payload["tool_name"]
    when "write" then format_write_content(input)
    else Toon.encode(input)
    end
  end

  # Formats write tool input with file path header and content body.
  # Content newlines are preserved so the TUI can render them as
  # separate lines, matching how read tool responses display file content.
  # @param input [Hash] tool input hash with "file_path" and "content" keys
  # @return [String] path + content with real newlines, or TOON-encoded hash when content is empty
  def format_write_content(input)
    path = input.dig("file_path").to_s
    content = input.dig("content").to_s
    return Toon.encode(input) if content.empty?

    "#{path}\n#{content}"
  end

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
    when "read", "edit", "write"
      input&.dig("file_path").to_s
    else
      truncate_lines(Toon.encode(input), max_lines: 2)
    end
  end
end
