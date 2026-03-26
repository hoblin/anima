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
  # Tags that never contain readable content — always removed.
  RENDER_TAGS = %w[script style noscript iframe svg].freeze

  # Structural elements stripped only when no semantic content container is found.
  STRUCTURAL_TAGS = %w[nav footer aside form header menu menuitem].freeze

  # Semantic HTML5 containers that hold primary page content.
  CONTENT_SELECTORS = ["main", "article", "[role='main']"].freeze

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
    public_send(method_name, body)
  end

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

  # Strips noise elements and converts semantic HTML to Markdown.
  # Warns when the extracted content is suspiciously short.
  #
  # @param body [String] HTML response body
  # @return [Hash] `{text: String, meta: String}`
  def text_html(body)
    markdown = html_to_markdown(body)
    meta = "[Converted: HTML → Markdown]"
    char_count = markdown.length
    if !body.empty? && char_count < Anima::Settings.min_web_content_chars
      meta += " [Warning: only #{char_count} chars extracted — content may be incomplete]"
    end
    {text: markdown, meta: meta}
  end

  # Passthrough for unregistered content types.
  #
  # @return [Hash] `{text: String, meta: nil}`
  def method_missing(_method_name, body, *)
    {text: body, meta: nil}
  end

  def respond_to_missing?(*, **)
    true
  end

  private

  # Converts HTML to Markdown using content-aware extraction.
  #
  # Prefers semantic containers (+<main>+, +<article>+, +[role="main"]+)
  # when available. Falls back to stripping structural noise from the
  # +<body>+. Rendering artifacts (scripts, styles, iframes, SVGs) are
  # always removed.
  #
  # @param html [String] raw HTML
  # @return [String] clean Markdown
  def html_to_markdown(html)
    doc = Nokogiri::HTML(html)
    doc.css(RENDER_TAGS.join(", ")).remove

    clean_html = extract_content(doc)
    markdown = ReverseMarkdown.convert(clean_html, unknown_tags: :bypass, github_flavored: true)
    collapse_whitespace(markdown)
  end

  # Extracts the primary content from a parsed HTML document.
  #
  # @param doc [Nokogiri::HTML::Document]
  # @return [String] inner HTML of the best content node
  def extract_content(doc)
    content = CONTENT_SELECTORS.lazy.filter_map { |sel| doc.at_css(sel) }.first
    return content.inner_html if content

    doc.css(STRUCTURAL_TAGS.join(", ")).remove
    doc.at("body")&.inner_html || doc.to_html
  end

  # Collapses excessive blank lines down to a single blank line.
  #
  # @param text [String]
  # @return [String]
  def collapse_whitespace(text)
    text.gsub(/\n{3,}/, "\n\n").strip
  end
end
