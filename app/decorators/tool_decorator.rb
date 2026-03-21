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

  # Factory: dispatches to the tool-specific decorator or passes through.
  #
  # @param tool_name [String] registered tool name
  # @param result [String, Hash] raw tool execution result
  # @return [String, Hash] decorated result (String) or original error Hash
  def self.call(tool_name, result)
    return result if result.is_a?(Hash) && result.key?(:error)

    klass_name = DECORATOR_MAP[tool_name]
    return result unless klass_name

    klass_name.constantize.new.call(result)
  end

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
