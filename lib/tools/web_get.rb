# frozen_string_literal: true

require "certifi"
require "httparty"

module Tools
  # Fetches content from a URL via HTTP GET. Returns a structured result with
  # the response body and Content-Type header so that {ToolDecorator} can apply
  # format-specific conversion (HTML → Markdown, JSON → TOON, etc.).
  #
  # The body is truncated to {Anima::Settings.max_web_response_bytes} before
  # decoration to cap memory usage on large responses.
  #
  # Only http and https schemes are allowed.
  class WebGet < Base
    def self.tool_name = "web_get"

    def self.description = "Fetch a URL."

    def self.input_schema
      {
        type: "object",
        properties: {
          url: {type: "string"}
        },
        required: ["url"]
      }
    end

    # @param input [Hash<String, Object>] string-keyed hash from the Anthropic API.
    #   Supports optional "timeout" key (seconds) to override the global
    #   web_request_timeout setting.
    # @return [Hash] `{body: String, content_type: String}` on success
    # @return [Hash] `{error: String}` on failure
    def execute(input)
      validate_and_fetch(input["url"].to_s, timeout: input["timeout"])
    end

    private

    def validate_and_fetch(url, timeout: nil)
      timeout ||= Anima::Settings.web_request_timeout
      scheme = URI.parse(url).scheme

      unless %w[http https].include?(scheme)
        return {error: "Only http and https URLs are supported, got: #{scheme.inspect}"}
      end

      response = HTTParty.get(url, timeout: timeout, follow_redirects: false, ssl_ca_file: Certifi.where)
      content_type = response.content_type || "text/plain"
      body = response.body.to_s
      body = strip_html_noise(body) if content_type.include?("text/html")

      {body: truncate_body(body), content_type: content_type}
    rescue URI::InvalidURIError => error
      {error: "Invalid URL: #{error.message}"}
    rescue Net::OpenTimeout, Net::ReadTimeout
      {error: "Request timed out after #{timeout} seconds"}
    rescue Errno::ECONNREFUSED
      {error: "Connection refused: #{url}"}
    rescue => error
      {error: "#{error.class}: #{error.message}"}
    end

    def truncate_body(body)
      max_bytes = Anima::Settings.max_web_response_bytes
      return body if body.bytesize <= max_bytes

      body.byteslice(0, max_bytes).scrub +
        "\n\n[Truncated: response exceeded #{max_bytes} bytes]"
    end

    # First-stage noise stripping — runs before truncation so that the
    # byte budget is spent on content, not on scripts/SVGs/metadata.
    # Each pattern targets one tag type for easy maintenance.
    # The decorator applies a second, structure-aware pass via Nokogiri.
    HTML_NOISE_PATTERNS = [
      %r{<head\b[^>]*>.*?</head>}mi,       # metadata, link/meta tags
      %r{<script\b[^>]*>.*?</script>}mi,   # JavaScript
      %r{<style\b[^>]*>.*?</style>}mi,      # CSS
      %r{<svg\b[^>]*>.*?</svg>}mi,          # inline graphics
      %r{<template\b[^>]*>.*?</template>}mi, # deferred markup
      %r{<noscript\b[^>]*>.*?</noscript>}mi  # JS-disabled fallbacks
    ].freeze
    private_constant :HTML_NOISE_PATTERNS

    def strip_html_noise(html)
      HTML_NOISE_PATTERNS.reduce(html) { |text, pattern| text.gsub(pattern, "") }
    end
  end
end
