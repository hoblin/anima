# frozen_string_literal: true

require "httparty"

module Providers
  class Anthropic
    include HTTParty

    base_uri "https://api.anthropic.com"

    TOKEN_PREFIX = "sk-ant-oat01-"
    TOKEN_MIN_LENGTH = 80
    API_VERSION = "2023-06-01"
    REQUIRED_BETA = "oauth-2025-04-20"

    # Anthropic requires this exact string as the first system block for OAuth
    # subscription tokens on Sonnet/Opus. Without it, /v1/messages returns 400.
    OAUTH_PASSPHRASE = "You are Claude Code, Anthropic's official CLI for Claude."

    # Rate limit header names for extraction
    RATE_LIMIT_HEADERS = {
      "5h_status" => "Anthropic-Ratelimit-Unified-5h-Status",
      "5h_reset" => "Anthropic-Ratelimit-Unified-5h-Reset",
      "5h_utilization" => "Anthropic-Ratelimit-Unified-5h-Utilization",
      "7d_status" => "Anthropic-Ratelimit-Unified-7d-Status",
      "7d_reset" => "Anthropic-Ratelimit-Unified-7d-Reset",
      "7d_utilization" => "Anthropic-Ratelimit-Unified-7d-Utilization"
    }.freeze

    # Response wrapper containing both the parsed body and API metrics.
    # Behaves like a Hash for backward compatibility (delegates to body).
    #
    # @!attribute [r] body
    #   @return [Hash] parsed API response
    # @!attribute [r] api_metrics
    #   @return [Hash, nil] rate limits and usage data
    ApiResponse = Data.define(:body, :api_metrics) do
      # Delegate Hash methods to body for backward compatibility.
      # Callers using response["content"] continue to work unchanged.
      def [](key) = body[key]
      def dig(...) = body.dig(...)
      def fetch(...) = body.fetch(...)
      def key?(key) = body.key?(key)
      def to_h = body
      def to_json(...) = body.to_json(...)
    end

    class Error < StandardError; end
    class AuthenticationError < Error; end
    class TokenFormatError < Error; end

    # Transient errors that may succeed on retry (network issues, rate limits, server errors).
    class TransientError < Error; end
    class RateLimitError < TransientError; end
    class ServerError < TransientError; end

    class << self
      def fetch_token
        return ENV["ANTHROPIC_API_KEY"] if ENV["ANTHROPIC_API_KEY"].present?
        token = CredentialStore.read("anthropic", "subscription_token")
        return token if token.present?
        return "sk-ant-oat01-#{"0" * 68}" if ENV["CI"]

        raise AuthenticationError, <<~MSG.strip
          No Anthropic subscription token found in credentials.
          Use the TUI token setup (Ctrl+a → a) to configure your token.
        MSG
      end

      def validate_token_format!(token)
        unless token.start_with?(TOKEN_PREFIX)
          raise TokenFormatError,
            "Token must start with '#{TOKEN_PREFIX}'. Got: '#{token[0..12]}...'"
        end

        unless token.length >= TOKEN_MIN_LENGTH
          raise TokenFormatError,
            "Token must be at least #{TOKEN_MIN_LENGTH} characters (got #{token.length})"
        end

        true
      end

      # Validate a token against the live Anthropic API.
      # Delegates to {#validate_credentials!} on a throwaway instance.
      #
      # @param token [String] Anthropic API token to validate
      # @return [true] when the API accepts the token
      # @raise [TransientError] on network failures or server errors (retryable)
      # @raise [AuthenticationError] on 401/403 (permanent)
      def validate_token_api!(token)
        provider = new(token)
        provider.validate_credentials!
      end
    end

    attr_reader :token

    def initialize(token = nil)
      @token = token || self.class.fetch_token
    end

    # Send a message to the Anthropic API and return the parsed response.
    #
    # @param model [String] Anthropic model identifier
    # @param messages [Array<Hash>] conversation messages
    # @param max_tokens [Integer] maximum tokens in the response
    # @param include_metrics [Boolean] when true, returns an {ApiResponse}
    #   wrapper with both body and api_metrics; when false (default),
    #   returns just the parsed body Hash for backward compatibility
    # @param options [Hash] additional parameters (e.g. +system:+, +tools:+)
    # @return [Hash, ApiResponse] parsed API response, or wrapper with metrics
    # @raise [TransientError] on network failures or server errors (retryable)
    # @raise [AuthenticationError] on 401/403 (permanent)
    # @raise [Error] on other API errors
    def create_message(model:, messages:, max_tokens:, include_metrics: false, **options)
      wrap_system_prompt!(options)
      body = {model: model, messages: messages, max_tokens: max_tokens}.merge(options)

      response = self.class.post(
        "/v1/messages",
        body: body.to_json,
        headers: request_headers,
        timeout: Anima::Settings.api_timeout
      )

      handle_response(response, include_metrics: include_metrics)
    rescue Errno::ECONNRESET, Net::ReadTimeout, Net::OpenTimeout, SocketError, EOFError => network_error
      raise TransientError, "#{network_error.class}: #{network_error.message}"
    end

    # Count tokens in a message payload without creating a message.
    # Uses the free Anthropic token counting endpoint.
    #
    # @param model [String] Anthropic model identifier
    # @param messages [Array<Hash>] conversation messages
    # @param options [Hash] additional parameters (e.g. +system:+, +tools:+)
    # @return [Integer] estimated input token count
    # @raise [Error] on API errors
    def count_tokens(model:, messages:, **options)
      wrap_system_prompt!(options)
      body = {model: model, messages: messages}.merge(options)

      response = self.class.post(
        "/v1/messages/count_tokens",
        body: body.to_json,
        headers: request_headers,
        timeout: Anima::Settings.api_timeout
      )

      result = handle_response(response)
      result["input_tokens"]
    rescue Errno::ECONNRESET, Net::ReadTimeout, Net::OpenTimeout, SocketError, EOFError => network_error
      raise TransientError, "#{network_error.class}: #{network_error.message}"
    end

    # Verify the token is accepted by Anthropic using the free models endpoint.
    # Returns +true+ on success; raises typed exceptions on failure so callers
    # can distinguish permanent auth problems from transient outages.
    #
    # @return [true] when the API accepts the token
    # @raise [AuthenticationError] on 401 (invalid token) or 403 (restricted credential)
    # @raise [RateLimitError] on 429
    # @raise [ServerError] on 5xx
    # @raise [TransientError] on network-level failures
    def validate_credentials!
      response = self.class.get(
        "/v1/models",
        headers: request_headers,
        timeout: Anima::Settings.api_timeout
      )

      case response.code
      when 200
        true
      when 401
        raise AuthenticationError,
          "Token rejected by Anthropic API (401). Re-run `claude setup-token` and use the TUI token setup (Ctrl+a → a)."
      when 403
        raise AuthenticationError,
          "Token not authorized for API access (403). This credential may be restricted to Claude Code only."
      else
        handle_response(response)
      end
    rescue Errno::ECONNRESET, Net::ReadTimeout, Net::OpenTimeout, SocketError, EOFError => network_error
      raise TransientError, "#{network_error.class}: #{network_error.message}"
    end

    private

    # Wraps the system parameter in the array-of-blocks format required by
    # Anthropic for OAuth tokens. The passphrase block is always present;
    # the caller's prompt (if any) is appended as the second block.
    #
    # @param options [Hash] mutable options hash (modified in place)
    # @return [void]
    def wrap_system_prompt!(options)
      prompt = options[:system]
      blocks = [{type: "text", text: OAUTH_PASSPHRASE}]
      blocks << {type: "text", text: prompt} if prompt
      options[:system] = blocks
    end

    def request_headers
      {
        "Authorization" => "Bearer #{token}",
        "anthropic-version" => API_VERSION,
        "anthropic-beta" => REQUIRED_BETA,
        "content-type" => "application/json"
      }
    end

    def handle_response(response, include_metrics: false)
      case response.code
      when 200
        body = response.parsed_response
        return body unless include_metrics

        ApiResponse.new(body: body, api_metrics: extract_api_metrics(response))
      when 400
        raise Error, "Bad request: #{error_message(response)}"
      when 401
        raise AuthenticationError,
          "Authentication failed (401): #{error_message(response)}. Re-run `claude setup-token` and use the TUI token setup (Ctrl+a → a)."
      when 403
        raise AuthenticationError,
          "Forbidden (403): #{error_message(response)}"
      when 429
        raise RateLimitError, "Rate limit exceeded: #{error_message(response)}"
      when 500..599
        raise ServerError, "Anthropic server error (#{response.code}): #{response.message}"
      else
        raise Error, "Unexpected response (#{response.code}): #{response.message}"
      end
    end

    # Extracts rate limit headers and usage data from an HTTParty response.
    #
    # @param response [HTTParty::Response] raw API response
    # @return [Hash] with "rate_limits" and "usage" string keys
    def extract_api_metrics(response)
      {
        "rate_limits" => extract_rate_limits(response.headers),
        "usage" => response.parsed_response&.dig("usage")
      }
    end

    # Extracts rate limit values from response headers.
    #
    # @param headers [Hash] HTTParty headers (case-insensitive)
    # @return [Hash] normalized rate limit data
    def extract_rate_limits(headers)
      return {} unless headers

      RATE_LIMIT_HEADERS.transform_values do |header_name|
        # HTTParty headers are strings; VCR replays them as arrays
        raw = headers[header_name]
        value = raw.is_a?(Array) ? raw.first : raw
        # Parse numeric values (utilization, reset timestamps)
        case value
        when /\A\d+\z/ then value.to_i
        when /\A\d+\.\d+\z/ then value.to_f
        else value
        end
      end
    end

    def error_message(response)
      response.parsed_response&.dig("error", "message") || response.message
    rescue JSON::ParserError, NoMethodError
      response.message
    end
  end
end
