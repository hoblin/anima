# frozen_string_literal: true

# Decorates tool_call events for display in the TUI.
# Hidden in basic mode — tool activity is represented by the
# aggregated tool counter instead. Verbose mode returns tool name
# and a formatted preview of the input arguments. Debug mode shows
# full untruncated input as pretty-printed JSON with tool_use_id.
#
# Think tool calls are special: "aloud" thoughts are shown in all
# view modes (with a thought bubble), while "inner" thoughts are
# visible only in verbose and debug modes.
class ToolCallDecorator < EventDecorator
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
      input: JSON.pretty_generate(payload["tool_input"] || {}),
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

  # Formats tool input for display, with tool-specific formatting for
  # known tools and generic JSON fallback for others.
  # @return [String] formatted input preview
  def format_input
    input = payload["tool_input"]
    json = input.to_json
    case payload["tool_name"]
    when "bash"
      "$ #{input&.dig("command")}"
    when "web_get", "web_fetch"
      "GET #{input&.dig("url")}"
    when "read_file", "edit_file", "write"
      input&.dig("file_path").to_s
    when "list_files"
      input&.dig("path") || input&.dig("pattern") || json
    when "search_files"
      input&.dig("pattern") || input&.dig("query") || json
    else
      truncate_lines(json, max_lines: 2)
    end
  end
end
