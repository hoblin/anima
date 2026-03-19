# frozen_string_literal: true

require "rails_helper"

RSpec.shared_examples "wraps network errors as TransientError" do
  [
    [Errno::ECONNRESET, "Connection reset by peer", /ECONNRESET/],
    [Net::ReadTimeout, "Net::ReadTimeout", /ReadTimeout/],
    [Net::OpenTimeout, "Net::OpenTimeout", /OpenTimeout/],
    [SocketError, "getaddrinfo: Name or service not known", /SocketError/],
    [EOFError, "end of file reached", /EOFError/]
  ].each do |error_class, message, pattern|
    it "wraps #{error_class}" do
      VCR.turned_off do
        stub_request(request_method, request_url).to_raise(error_class.new(message))
        expect { perform_request }.to raise_error(Providers::Anthropic::TransientError, pattern)
      end
    end
  end
end

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

    it "defines the OAuth passphrase for system prompt prefixing" do
      expect(described_class::OAUTH_PASSPHRASE)
        .to eq("You are Claude Code, Anthropic's official CLI for Claude.")
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
    it "sends a properly formatted request to the messages API", :vcr do
      real_token = CredentialStore.read("anthropic", "subscription_token") || valid_token
      real_provider = described_class.new(real_token)

      result = real_provider.create_message(
        model: "claude-sonnet-4-20250514",
        messages: [{role: "user", content: "Reply with the single word OK"}],
        max_tokens: 100
      )

      expect(result["content"].first["text"]).to be_present
    end

    it "wraps system prompt in array format with OAuth passphrase", :vcr do
      real_token = CredentialStore.read("anthropic", "subscription_token") || valid_token
      real_provider = described_class.new(real_token)

      result = real_provider.create_message(
        model: "claude-sonnet-4-20250514",
        messages: [{role: "user", content: "Reply with the single word OK"}],
        max_tokens: 100,
        system: "You are helpful",
        temperature: 0.0
      )

      expect(result["content"].first["text"]).to be_present
    end

    it "succeeds without system prompt", :vcr do
      real_token = CredentialStore.read("anthropic", "subscription_token") || valid_token
      real_provider = described_class.new(real_token)

      result = real_provider.create_message(
        model: "claude-sonnet-4-20250514",
        messages: [{role: "user", content: "Reply with the single word OK"}],
        max_tokens: 100,
        temperature: 0.0
      )

      expect(result["content"].first["text"]).to be_present
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

    it "raises RateLimitError on 429 rate limit" do
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
      }.to raise_error(Providers::Anthropic::RateLimitError, /Rate limit/)
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

    it "raises ServerError on 500 server error" do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 500, body: "Internal Server Error")

      expect {
        provider.create_message(
          model: "claude-sonnet-4-20250514",
          messages: [{role: "user", content: "Hi"}],
          max_tokens: 100
        )
      }.to raise_error(Providers::Anthropic::ServerError, /server error/)
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

    include_examples "wraps network errors as TransientError" do
      let(:request_method) { :post }
      let(:request_url) { "https://api.anthropic.com/v1/messages" }
      let(:perform_request) do
        provider.create_message(
          model: "claude-sonnet-4-20250514",
          messages: [{role: "user", content: "Hi"}],
          max_tokens: 100
        )
      end
    end
  end

  describe "#count_tokens" do
    it "sends a request to the token counting endpoint", :vcr do
      real_token = CredentialStore.read("anthropic", "subscription_token") || valid_token
      real_provider = described_class.new(real_token)

      result = real_provider.count_tokens(
        model: "claude-sonnet-4-20250514",
        messages: [{role: "user", content: "Hello"}]
      )

      expect(result).to be_a(Integer)
    end

    it "wraps system prompt in array format with OAuth passphrase", :vcr do
      real_token = CredentialStore.read("anthropic", "subscription_token") || valid_token
      real_provider = described_class.new(real_token)

      result = real_provider.count_tokens(
        model: "claude-sonnet-4-20250514",
        messages: [{role: "user", content: "Hi"}],
        system: "You are helpful"
      )

      expect(result).to be_a(Integer)
    end

    it "raises Error on API failure" do
      stub_request(:post, "https://api.anthropic.com/v1/messages/count_tokens")
        .to_return(
          status: 400,
          body: {error: {message: "invalid model"}}.to_json,
          headers: {"content-type" => "application/json"}
        )

      expect {
        provider.count_tokens(
          model: "bad-model",
          messages: [{role: "user", content: "Hi"}]
        )
      }.to raise_error(Providers::Anthropic::Error, /Bad request/)
    end

    include_examples "wraps network errors as TransientError" do
      let(:request_method) { :post }
      let(:request_url) { "https://api.anthropic.com/v1/messages/count_tokens" }
      let(:perform_request) do
        provider.count_tokens(
          model: "claude-sonnet-4-20250514",
          messages: [{role: "user", content: "Hi"}]
        )
      end
    end
  end

  describe "#validate_credentials!" do
    it "returns true on 200", vcr: "anthropic/models_200" do
      real_token = CredentialStore.read("anthropic", "subscription_token") || valid_token
      real_provider = described_class.new(real_token)
      expect(real_provider.validate_credentials!).to be true
    end

    it "raises AuthenticationError on 401", vcr: "anthropic/models_401" do
      expect { provider.validate_credentials! }
        .to raise_error(Providers::Anthropic::AuthenticationError, /Token rejected/)
    end

    it "raises AuthenticationError on 403", vcr: "anthropic/models_403" do
      expect { provider.validate_credentials! }
        .to raise_error(Providers::Anthropic::AuthenticationError, /not authorized/)
    end

    it "raises ServerError on 500", vcr: "anthropic/models_500" do
      expect { provider.validate_credentials! }
        .to raise_error(Providers::Anthropic::ServerError)
    end

    it "raises ServerError on 529", vcr: "anthropic/models_529" do
      expect { provider.validate_credentials! }
        .to raise_error(Providers::Anthropic::ServerError)
    end

    it "raises RateLimitError on 429", vcr: "anthropic/models_429" do
      expect { provider.validate_credentials! }
        .to raise_error(Providers::Anthropic::RateLimitError)
    end
  end

  describe "#wrap_system_prompt!" do
    let(:passphrase_block) { {type: "text", text: described_class::OAUTH_PASSPHRASE} }

    it "always includes the passphrase as the first block" do
      options = {system: "You are helpful"}
      provider.send(:wrap_system_prompt!, options)

      expect(options[:system]).to be_an(Array)
      expect(options[:system].first).to eq(passphrase_block)
    end

    it "appends the caller's system prompt as the second block" do
      options = {system: "You are helpful"}
      provider.send(:wrap_system_prompt!, options)

      expect(options[:system].last).to eq({type: "text", text: "You are helpful"})
      expect(options[:system].length).to eq(2)
    end

    it "produces a single-element array when no system prompt is provided" do
      options = {}
      provider.send(:wrap_system_prompt!, options)

      expect(options[:system]).to eq([passphrase_block])
    end
  end

  describe "error class hierarchy" do
    it "AuthenticationError inherits from Error" do
      expect(Providers::Anthropic::AuthenticationError).to be < Providers::Anthropic::Error
    end

    it "TokenFormatError inherits from Error" do
      expect(Providers::Anthropic::TokenFormatError).to be < Providers::Anthropic::Error
    end

    it "TransientError inherits from Error" do
      expect(Providers::Anthropic::TransientError).to be < Providers::Anthropic::Error
    end

    it "RateLimitError inherits from TransientError" do
      expect(Providers::Anthropic::RateLimitError).to be < Providers::Anthropic::TransientError
    end

    it "ServerError inherits from TransientError" do
      expect(Providers::Anthropic::ServerError).to be < Providers::Anthropic::TransientError
    end
  end
end
