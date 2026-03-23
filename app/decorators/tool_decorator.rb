# frozen_string_literal: true

# Base class for server-side tool response decoration. Transforms raw tool
# results into LLM-optimized formats before they enter the event stream.
#
# This is a separate decorator type from {EventDecorator}: EventDecorator
# formats events for clients (TUI/web), while ToolDecorator formats tool
# responses for the LLM. They sit at different points in the pipeline:
#
#   Tool executes → ToolDecorator transforms → event stream → EventDecorator renders
#
# Subclasses implement {#call} to transform a tool's raw result into an
# LLM-friendly string. Each tool can have its own ToolDecorator subclass
# (e.g. {WebGetToolDecorator}) registered in {DECORATOR_MAP}.
#
# @example Decorating a tool result
#   ToolDecorator.call("web_get", {body: html, content_type: "text/html"})
#   #=> "[Converted: HTML → Markdown]\n\n# Page Title\n..."
class ToolDecorator
  DECORATOR_MAP = {
    "web_get" => "WebGetToolDecorator"
  }.freeze

  # Factory: dispatches to the tool-specific decorator, then sanitizes
  # the result for safe LLM consumption.
  #
  # Sanitization guarantees the final string is UTF-8 encoded, free of
  # ANSI escape codes, and stripped of control characters that carry no
  # meaning for an LLM. This is the single gate — no tool or decorator
  # subclass needs to think about encoding or terminal noise.
  #
  # @param tool_name [String] registered tool name
  # @param result [String, Hash] raw tool execution result
  # @return [String, Hash] sanitized result (String) or original error Hash
  def self.call(tool_name, result)
    return result if result.is_a?(Hash) && result.key?(:error)

    klass_name = DECORATOR_MAP[tool_name]
    result = klass_name.constantize.new.call(result) if klass_name

    sanitize_for_llm(result)
  end

  # Ensures a tool result string is safe for LLM consumption:
  #   1. Force-encode to UTF-8, replacing invalid/undefined bytes with U+FFFD
  #   2. Strip ANSI escape codes (CSI, OSC, and single-character escapes)
  #   3. Strip C0 control characters except newline and tab
  #
  # Non-string results pass through unchanged.
  #
  # @param result [String, Object] tool output to sanitize
  # @return [String, Object] sanitized string or original object
  def self.sanitize_for_llm(result)
    return result unless result.is_a?(String)

    result
      .encode("UTF-8", invalid: :replace, undef: :replace, replace: "\uFFFD")
      .gsub(/\e\[[0-9;]*[A-Za-z]|\e\][^\a\e]*(?:\a|\e\\)|\e[()][0-9A-Za-z]|\e[>=<78NOMDEHcn]/, "")
      .gsub(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
  end
  private_class_method :sanitize_for_llm

  # Subclasses override to transform the raw tool result.
  #
  # @param result [String, Hash] raw tool execution result
  # @return [String] LLM-optimized content
  def call(result)
    raise NotImplementedError, "#{self.class} must implement #call"
  end

  private

  # Combines decorated text with an optional metadata tag so the LLM
  # knows the content was transformed.
  #
  # @param text [String] the transformed content
  # @param meta [String, nil] conversion tag (e.g. "[Converted: HTML → Markdown]")
  # @return [String]
  def assemble(text:, meta:)
    meta ? "#{meta}\n\n#{text}" : text
  end
end
