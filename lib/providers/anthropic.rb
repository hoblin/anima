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

    class Error < StandardError; end
    class AuthenticationError < Error; end
    class TokenFormatError < Error; end

    # Transient errors that may succeed on retry (network issues, rate limits, server errors).
    class TransientError < Error; end
    class RateLimitError < TransientError; end
    class ServerError < TransientError; end

    class << self
      def fetch_token
        token = CredentialStore.read("anthropic", "subscription_token")
        raise AuthenticationError, <<~MSG.strip if token.blank?
          No Anthropic subscription token found in credentials.
          Use the TUI token setup (Ctrl+a → a) to configure your token.
        MSG
        token
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
    # @param options [Hash] additional parameters (e.g. +system:+, +tools:+)
    # @return [Hash] parsed API response
    # @raise [TransientError] on network failures or server errors (retryable)
    # @raise [AuthenticationError] on 401/403 (permanent)
    # @raise [Error] on other API errors
    def create_message(model:, messages:, max_tokens:, **options)
      wrap_system_prompt!(options)
      body = {model: model, messages: messages, max_tokens: max_tokens}.merge(options)

      response = self.class.post(
        "/v1/messages",
        body: body.to_json,
        headers: request_headers,
        timeout: Anima::Settings.api_timeout
      )

      handle_response(response)
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

    # Converts +options[:system]+ from a plain string to the array-of-blocks
    # format required by Anthropic for OAuth tokens. Prepends the mandatory
    # passphrase as the first block; the model follows the last identity
    # instruction, so the caller's prompt takes precedence.
    #
    # @param options [Hash] mutable options hash (modified in place)
    # @return [void]
    def wrap_system_prompt!(options)
      return unless (prompt = options[:system])

      options[:system] = [
        {type: "text", text: OAUTH_PASSPHRASE},
        {type: "text", text: prompt}
      ]
    end

    def request_headers
      {
        "Authorization" => "Bearer #{token}",
        "anthropic-version" => API_VERSION,
        "anthropic-beta" => REQUIRED_BETA,
        "content-type" => "application/json"
      }
    end

    def handle_response(response)
      case response.code
      when 200
        response.parsed_response
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

    def error_message(response)
      response.parsed_response&.dig("error", "message") || response.message
    rescue JSON::ParserError, NoMethodError
      response.message
    end
  end
end
