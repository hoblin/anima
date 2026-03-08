# frozen_string_literal: true

require "httparty"

module Tools
  # Fetches content from a URL via HTTP GET. Returns the response body
  # as plain text, truncated to {MAX_RESPONSE_BYTES} to prevent memory issues.
  #
  # Only http and https schemes are allowed.
  class WebGet < Base
    MAX_RESPONSE_BYTES = 100_000
    REQUEST_TIMEOUT = 10

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
    # @return [String] response body (possibly truncated)
    # @return [Hash] with :error key on failure
    def execute(input)
      validate_and_fetch(input["url"].to_s)
    end

    private

    def validate_and_fetch(url)
      scheme = URI.parse(url).scheme

      unless %w[http https].include?(scheme)
        return {error: "Only http and https URLs are supported, got: #{scheme.inspect}"}
      end

      truncate_body(HTTParty.get(url, timeout: REQUEST_TIMEOUT, follow_redirects: false).body.to_s)
    rescue URI::InvalidURIError => error
      {error: "Invalid URL: #{error.message}"}
    rescue Net::OpenTimeout, Net::ReadTimeout
      {error: "Request timed out after #{REQUEST_TIMEOUT} seconds"}
    rescue Errno::ECONNREFUSED
      {error: "Connection refused: #{url}"}
    rescue => error
      {error: "#{error.class}: #{error.message}"}
    end

    def truncate_body(body)
      return body if body.bytesize <= MAX_RESPONSE_BYTES

      body.byteslice(0, MAX_RESPONSE_BYTES) +
        "\n\n[Truncated: response exceeded #{MAX_RESPONSE_BYTES} bytes]"
    end
  end
end
