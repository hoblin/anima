# frozen_string_literal: true

# Base class for server-side tool response decoration. Transforms raw tool
# results into LLM-optimized formats before they enter the message stream.
#
# This is a separate decorator type from {MessageDecorator}: MessageDecorator
# formats messages for clients (TUI/web), while ToolDecorator formats tool
# responses for the LLM. They sit at different points in the pipeline:
#
#   Tool executes → ToolDecorator transforms → message stream → MessageDecorator renders
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

  # Ensures a tool result string is safe for LLM consumption by
  # composing {encode_utf8}, {strip_ansi}, and {strip_control_chars}.
  #
  # Non-string results pass through unchanged.
  #
  # @param result [String, Object] tool output to sanitize
  # @return [String, Object] sanitized string or original object
  def self.sanitize_for_llm(result)
    return result unless result.is_a?(String)

    strip_control_chars(strip_ansi(encode_utf8(result)))
  end
  private_class_method :sanitize_for_llm

  # Force-encodes a string to UTF-8, replacing invalid or undefined
  # bytes with the Unicode replacement character (U+FFFD).
  #
  # @param str [String] input in any encoding (commonly ASCII-8BIT from PTY)
  # @return [String] valid UTF-8 string
  def self.encode_utf8(str)
    str.encode("UTF-8", invalid: :replace, undef: :replace, replace: "\uFFFD")
  end
  private_class_method :encode_utf8

  # CSI (colors, cursor, DEC private modes), OSC (terminal title),
  # charset designation, single-char commands
  ANSI_ESCAPE = /\e\[[?>=<0-9;]*[A-Za-z]|\e\][^\a\e]*(?:\a|\e\\)|\e[()][0-9A-Za-z]|\e[>=<78NOMDEHcn]/
  private_constant :ANSI_ESCAPE

  # Strips ANSI escape sequences that are meaningless noise to an LLM
  # but can dominate terminal output payloads.
  #
  # @param str [String] UTF-8 string possibly containing escape codes
  # @return [String] cleaned string
  def self.strip_ansi(str)
    str.gsub(ANSI_ESCAPE, "")
  end
  private_class_method :strip_ansi

  # Strips C0 control characters (NUL, BEL, BS, CR, etc.) that carry
  # no meaning for an LLM. Preserves newline (\n) and tab (\t).
  #
  # @param str [String] UTF-8 string possibly containing control chars
  # @return [String] cleaned string
  def self.strip_control_chars(str)
    str.gsub(/[\x00-\x08\x0B-\x0D\x0E-\x1F\x7F]/, "")
  end
  private_class_method :strip_control_chars

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
