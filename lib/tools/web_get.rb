# frozen_string_literal: true

require "httparty"

module Tools
  # Fetches content from a URL via HTTP GET. Returns the response body
  # as plain text, truncated to {Anima::Settings.max_web_response_bytes} to prevent memory issues.
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

      timeout = Anima::Settings.web_request_timeout
      truncate_body(HTTParty.get(url, timeout: timeout, follow_redirects: false).body.to_s)
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

      body.byteslice(0, max_bytes) +
        "\n\n[Truncated: response exceeded #{max_bytes} bytes]"
    end
  end
end
