# frozen_string_literal: true

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

    def self.description = "Fetch content from a URL via HTTP GET and return the response body"

    def self.input_schema
      {
        type: "object",
        properties: {
          url: {type: "string", description: "The URL to fetch (http or https)"}
        },
        required: ["url"]
      }
    end

    # @param input [Hash<String, Object>] string-keyed hash from the Anthropic API
    # @return [Hash] `{body: String, content_type: String}` on success
    # @return [Hash] `{error: String}` on failure
    def execute(input)
      validate_and_fetch(input["url"].to_s)
    end

    private

    def validate_and_fetch(url)
      timeout = Anima::Settings.web_request_timeout
      scheme = URI.parse(url).scheme

      unless %w[http https].include?(scheme)
        return {error: "Only http and https URLs are supported, got: #{scheme.inspect}"}
      end

      response = HTTParty.get(url, timeout: timeout, follow_redirects: false)
      body = truncate_body(response.body.to_s)
      content_type = response.content_type || "text/plain"

      {body: body, content_type: content_type}
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
  end
end
