# frozen_string_literal: true

require "rails_helper"

RSpec.describe Providers::Anthropic do
  let(:valid_token) { "sk-ant-oat01-#{"a" * 68}" }
  let(:provider) { described_class.new(valid_token) }

  describe "constants" do
    it "defines the expected token prefix" do
      expect(described_class::TOKEN_PREFIX).to eq("sk-ant-oat01-")
    end

    it "requires minimum 80 character tokens" do
      expect(described_class::TOKEN_MIN_LENGTH).to eq(80)
    end

    it "uses the correct API version" do
      expect(described_class::API_VERSION).to eq("2023-06-01")
    end

    it "requires the OAuth beta header" do
      expect(described_class::REQUIRED_BETA).to eq("oauth-2025-04-20")
    end
  end

  describe ".validate_token_format!" do
    it "accepts a valid token" do
      expect(described_class.validate_token_format!(valid_token)).to be true
    end

    it "rejects a token with wrong prefix" do
      expect {
        described_class.validate_token_format!("sk-ant-api03-#{"a" * 68}")
      }.to raise_error(
        Providers::Anthropic::TokenFormatError,
        /must start with 'sk-ant-oat01-'/
      )
    end

    it "rejects a token that is too short" do
      short_token = "sk-ant-oat01-#{"a" * 10}"
      expect {
        described_class.validate_token_format!(short_token)
      }.to raise_error(
        Providers::Anthropic::TokenFormatError,
        /at least 80 characters/
      )
    end

    it "accepts a token of exactly minimum length" do
      boundary_token = "sk-ant-oat01-#{"a" * 67}"
      expect(boundary_token.length).to eq(80)
      expect(described_class.validate_token_format!(boundary_token)).to be true
    end
  end

  describe ".fetch_token" do
    context "when token is configured in credentials" do
      before do
        allow(Rails.application.credentials).to receive(:dig)
          .with(:anthropic, :subscription_token)
          .and_return(valid_token)
      end

      it "returns the token" do
        expect(described_class.fetch_token).to eq(valid_token)
      end
    end

    context "when token is missing from credentials" do
      before do
        allow(Rails.application.credentials).to receive(:dig)
          .with(:anthropic, :subscription_token)
          .and_return(nil)
      end

      it "raises AuthenticationError with setup instructions" do
        expect {
          described_class.fetch_token
        }.to raise_error(
          Providers::Anthropic::AuthenticationError,
          /No Anthropic subscription token found/
        )
      end
    end
  end

  describe ".validate!" do
    before do
      allow(Rails.application.credentials).to receive(:dig)
        .with(:anthropic, :subscription_token)
        .and_return(valid_token)
    end

    it "validates format and makes a test API call" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .with(
          headers: {
            "Authorization" => "Bearer #{valid_token}",
            "anthropic-version" => "2023-06-01",
            "anthropic-beta" => "oauth-2025-04-20"
          }
        )
        .to_return(status: 200, body: {content: [{text: "Hi"}]}.to_json)

      expect(described_class.validate!).to be true
    end

    it "raises AuthenticationError on 401 response" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(
          status: 401,
          body: {error: {message: "invalid token"}}.to_json,
          headers: {"content-type" => "application/json"}
        )

      expect {
        described_class.validate!
      }.to raise_error(
        Providers::Anthropic::AuthenticationError,
        /Token rejected by Anthropic API/
      )
    end

    it "raises AuthenticationError on 403 response" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(
          status: 403,
          body: {error: {message: "restricted"}}.to_json,
          headers: {"content-type" => "application/json"}
        )

      expect {
        described_class.validate!
      }.to raise_error(
        Providers::Anthropic::AuthenticationError,
        /not authorized for API access/
      )
    end
  end

  describe "#initialize" do
    it "accepts a token argument" do
      provider = described_class.new(valid_token)
      expect(provider.token).to eq(valid_token)
    end

    it "fetches token from credentials when no argument given" do
      allow(Rails.application.credentials).to receive(:dig)
        .with(:anthropic, :subscription_token)
        .and_return(valid_token)

      provider = described_class.new
      expect(provider.token).to eq(valid_token)
    end
  end

  describe "#create_message" do
    it "sends a properly formatted request to the messages API" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .with(
          body: {
            model: "claude-sonnet-4-20250514",
            messages: [{role: "user", content: "Hello"}],
            max_tokens: 1024
          }.to_json,
          headers: {
            "Authorization" => "Bearer #{valid_token}",
            "anthropic-version" => "2023-06-01",
            "anthropic-beta" => "oauth-2025-04-20",
            "content-type" => "application/json"
          }
        )
        .to_return(
          status: 200,
          body: {
            id: "msg_123",
            content: [{type: "text", text: "Hello!"}],
            model: "claude-sonnet-4-20250514",
            role: "assistant"
          }.to_json,
          headers: {"content-type" => "application/json"}
        )

      result = provider.create_message(
        model: "claude-sonnet-4-20250514",
        messages: [{role: "user", content: "Hello"}],
        max_tokens: 1024
      )

      expect(result["content"].first["text"]).to eq("Hello!")
    end

    it "passes additional options through to the API" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .with(
          body: hash_including("system" => "You are helpful", "temperature" => 0.7)
        )
        .to_return(
          status: 200,
          body: {content: [{text: "Hi"}]}.to_json,
          headers: {"content-type" => "application/json"}
        )

      provider.create_message(
        model: "claude-sonnet-4-20250514",
        messages: [{role: "user", content: "Hi"}],
        max_tokens: 100,
        system: "You are helpful",
        temperature: 0.7
      )
    end

    it "raises Error on 400 response" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(
          status: 400,
          body: {error: {message: "invalid model"}}.to_json,
          headers: {"content-type" => "application/json"}
        )

      expect {
        provider.create_message(
          model: "bad-model",
          messages: [{role: "user", content: "Hi"}],
          max_tokens: 100
        )
      }.to raise_error(Providers::Anthropic::Error, /Bad request/)
    end

    it "raises Error on 429 rate limit" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(
          status: 429,
          body: {error: {message: "rate limited"}}.to_json,
          headers: {"content-type" => "application/json"}
        )

      expect {
        provider.create_message(
          model: "claude-sonnet-4-20250514",
          messages: [{role: "user", content: "Hi"}],
          max_tokens: 100
        )
      }.to raise_error(Providers::Anthropic::Error, /Rate limit/)
    end

    it "raises AuthenticationError on 401 response" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(
          status: 401,
          body: {error: {message: "invalid api key"}}.to_json,
          headers: {"content-type" => "application/json"}
        )

      expect {
        provider.create_message(
          model: "claude-sonnet-4-20250514",
          messages: [{role: "user", content: "Hi"}],
          max_tokens: 100
        )
      }.to raise_error(Providers::Anthropic::AuthenticationError, /Authentication failed/)
    end

    it "raises AuthenticationError on 403 response" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(
          status: 403,
          body: {error: {message: "forbidden"}}.to_json,
          headers: {"content-type" => "application/json"}
        )

      expect {
        provider.create_message(
          model: "claude-sonnet-4-20250514",
          messages: [{role: "user", content: "Hi"}],
          max_tokens: 100
        )
      }.to raise_error(Providers::Anthropic::AuthenticationError, /Forbidden/)
    end

    it "raises Error on 500 server error" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 500, body: "Internal Server Error")

      expect {
        provider.create_message(
          model: "claude-sonnet-4-20250514",
          messages: [{role: "user", content: "Hi"}],
          max_tokens: 100
        )
      }.to raise_error(Providers::Anthropic::Error, /server error/)
    end

    it "raises Error on unexpected status code" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 418, body: "I'm a teapot")

      expect {
        provider.create_message(
          model: "claude-sonnet-4-20250514",
          messages: [{role: "user", content: "Hi"}],
          max_tokens: 100
        )
      }.to raise_error(Providers::Anthropic::Error, /Unexpected response/)
    end
  end

  describe "error class hierarchy" do
    it "AuthenticationError inherits from Error" do
      expect(Providers::Anthropic::AuthenticationError).to be < Providers::Anthropic::Error
    end

    it "TokenFormatError inherits from Error" do
      expect(Providers::Anthropic::TokenFormatError).to be < Providers::Anthropic::Error
    end
  end
end
