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
    VALIDATION_MODEL = "claude-sonnet-4-20250514"

    class Error < StandardError; end
    class AuthenticationError < Error; end
    class TokenFormatError < Error; end

    class << self
      def validate!
        token = fetch_token
        validate_token_format!(token)
        validate_token_api!(token)
        true
      end

      def fetch_token
        token = Rails.application.credentials.dig(:anthropic, :subscription_token)
        raise AuthenticationError, <<~MSG.strip if token.blank?
          No Anthropic subscription token found in credentials.
          Run: EDITOR=vim bin/rails credentials:edit
          Add:
            anthropic:
              subscription_token: sk-ant-oat01-YOUR_TOKEN_HERE
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

      def validate_token_api!(token)
        provider = new(token)
        provider.validate_credentials!
      end
    end

    attr_reader :token

    def initialize(token = nil)
      @token = token || self.class.fetch_token
    end

    def create_message(model:, messages:, max_tokens:, **options)
      body = {model: model, messages: messages, max_tokens: max_tokens}.merge(options)

      response = self.class.post(
        "/v1/messages",
        body: body.to_json,
        headers: request_headers
      )

      handle_response(response)
    end

    def validate_credentials!
      response = self.class.post(
        "/v1/messages",
        body: {
          model: VALIDATION_MODEL,
          messages: [{role: "user", content: "Hi"}],
          max_tokens: 1
        }.to_json,
        headers: request_headers
      )

      case response.code
      when 200
        true
      when 401
        raise AuthenticationError,
          "Token rejected by Anthropic API (401). Re-run `claude setup-token` and update credentials."
      when 403
        raise AuthenticationError,
          "Token not authorized for API access (403). This credential may be restricted to Claude Code only."
      else
        handle_response(response)
      end
    end

    private

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
          "Authentication failed (401): #{error_message(response)}. Re-run `claude setup-token` and update credentials."
      when 403
        raise AuthenticationError,
          "Forbidden (403): #{error_message(response)}"
      when 429
        raise Error, "Rate limit exceeded: #{error_message(response)}"
      when 500..599
        raise Error, "Anthropic server error (#{response.code}): #{response.message}"
      else
        raise Error, "Unexpected response (#{response.code}): #{response.message}"
      end
    end

    def error_message(response)
      response.parsed_response&.dig("error", "message") || response.message
    rescue
      response.message
    end
  end
end
