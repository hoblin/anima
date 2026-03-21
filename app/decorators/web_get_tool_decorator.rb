# frozen_string_literal: true

require "reverse_markdown"
require "toon"

# Transforms {Tools::WebGet} responses for LLM consumption by detecting
# the Content-Type header and applying format-specific conversion.
#
# Content-Type maps to a method name via simple string normalization:
#   "application/json" → {#application_json}
#   "text/html"        → {#text_html}
#   "text/plain"       → method_missing → passthrough
#
# Adding a new format = adding one method. Unknown types fall through
# {#method_missing} and pass through unchanged.
#
# @example
#   decorator = WebGetToolDecorator.new
#   decorator.call(body: "<h1>Hi</h1>", content_type: "text/html")
#   #=> "[Converted: HTML → Markdown]\n\n# Hi"
class WebGetToolDecorator < ToolDecorator
  # HTML elements that carry no useful content for an LLM.
  NOISE_TAGS = %w[script style nav footer aside form noscript iframe
    svg header menu menuitem].freeze

  # @param result [Hash] `{body: String, content_type: String}`
  # @return [String] LLM-optimized content with conversion metadata tag
  def call(result)
    return result.to_s unless result.is_a?(Hash) && result.key?(:body)

    body = result[:body].to_s
    content_type = result[:content_type] || "text/plain"
    decorated = decorate(body, content_type: content_type)

    assemble(**decorated)
  end

  # Dispatches to the format-specific method derived from Content-Type.
  #
  # @param body [String] raw response body
  # @param content_type [String] HTTP Content-Type header value
  # @return [Hash] `{text: String, meta: String|nil}`
  def decorate(body, content_type:)
    method_name = content_type.split(";").first.strip.tr("/", "_").tr("-", "_")
    send(method_name, body)
  end

  # Passthrough for unregistered content types.
  #
  # @return [Hash] `{text: String, meta: nil}`
  def method_missing(_method_name, body, *)
    {text: body.to_s, meta: nil}
  end

  def respond_to_missing?(*, **)
    true
  end

  private

  # Compresses JSON using TOON (Token-Optimized Object Notation) for
  # ~40% token savings on typical JSON arrays.
  #
  # @param body [String] JSON response body
  # @return [Hash] `{text: String, meta: String}`
  def application_json(body)
    parsed = JSON.parse(body)
    {text: Toon.encode(parsed), meta: "[Converted: JSON → TOON]"}
  rescue JSON::ParserError
    {text: body, meta: nil}
  end

  # Strips noise elements (scripts, styles, nav, ads) and converts
  # semantic HTML to Markdown for clean LLM consumption.
  #
  # @param body [String] HTML response body
  # @return [Hash] `{text: String, meta: String}`
  def text_html(body)
    markdown = html_to_markdown(body)
    {text: markdown, meta: "[Converted: HTML → Markdown]"}
  end

  # Strips noise HTML elements then converts to Markdown.
  #
  # @param html [String] raw HTML
  # @return [String] clean Markdown
  def html_to_markdown(html)
    doc = Nokogiri::HTML(html)
    NOISE_TAGS.each { |tag| doc.css(tag).remove }
    clean_html = doc.at("body")&.inner_html || doc.to_html
    markdown = ReverseMarkdown.convert(clean_html, unknown_tags: :bypass, github_flavored: true)
    collapse_whitespace(markdown)
  end

  # Collapses excessive blank lines down to a single blank line.
  #
  # @param text [String]
  # @return [String]
  def collapse_whitespace(text)
    text.gsub(/\n{3,}/, "\n\n").strip
  end
end
