# frozen_string_literal: true

require "rails_helper"

RSpec.describe Providers::Anthropic do
  let(:fake_token) { "sk-ant-oat01-#{"a" * 68}" }
  let(:real_token) { CredentialStore.read("anthropic", "subscription_token") || fake_token }
  let(:provider) { described_class.new(fake_token) }
  let(:real_provider) { described_class.new(real_token) }

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
      expect(described_class.validate_token_format!(fake_token)).to be true
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
    context "when token is configured in secrets" do
      before do
        Secret.write("anthropic", "subscription_token" => fake_token)
      end

      it "returns the token" do
        expect(described_class.fetch_token).to eq(fake_token)
      end
    end
  end

  describe "#initialize" do
    it "accepts a token argument" do
      provider = described_class.new(fake_token)
      expect(provider.token).to eq(fake_token)
    end

    it "fetches token from secrets when no argument given" do
      Secret.write("anthropic", "subscription_token" => fake_token)

      provider = described_class.new
      expect(provider.token).to eq(fake_token)
    end
  end

  describe "#create_message" do
    it "sends a properly formatted request to the messages API", :vcr do
      result = real_provider.create_message(
        model: "claude-sonnet-4-20250514",
        messages: [{role: "user", content: "Reply with the single word OK"}],
        max_tokens: 8192
      )

      expect(result["content"].first["text"]).to be_present
    end

    it "wraps system prompt in array format with OAuth passphrase", :vcr do
      result = real_provider.create_message(
        model: "claude-sonnet-4-20250514",
        messages: [{role: "user", content: "Reply with the single word OK"}],
        max_tokens: 8192,
        system: "You are helpful",
        temperature: 0.0
      )

      expect(result["content"].first["text"]).to be_present
    end

    it "succeeds without system prompt", :vcr do
      result = real_provider.create_message(
        model: "claude-sonnet-4-20250514",
        messages: [{role: "user", content: "Reply with the single word OK"}],
        max_tokens: 8192,
        temperature: 0.0
      )

      expect(result["content"].first["text"]).to be_present
    end

    it "raises Error on invalid model", :vcr do
      expect {
        real_provider.create_message(
          model: "bad-model",
          messages: [{role: "user", content: "Hi"}],
          max_tokens: 8192
        )
      }.to raise_error(Providers::Anthropic::Error)
    end

    it "raises AuthenticationError on 401 response", :vcr do
      expect {
        provider.create_message(
          model: "claude-sonnet-4-20250514",
          messages: [{role: "user", content: "Hi"}],
          max_tokens: 8192
        )
      }.to raise_error(Providers::Anthropic::AuthenticationError, /Authentication failed/)
    end

    it "raises AuthenticationError on 403 response", :vcr do
      expect {
        provider.create_message(
          model: "claude-sonnet-4-20250514",
          messages: [{role: "user", content: "Hi"}],
          max_tokens: 8192
        )
      }.to raise_error(Providers::Anthropic::AuthenticationError, /Forbidden/)
    end

    it "raises RateLimitError on 429 rate limit", :vcr do
      expect {
        provider.create_message(
          model: "claude-sonnet-4-20250514",
          messages: [{role: "user", content: "Hi"}],
          max_tokens: 8192
        )
      }.to raise_error(Providers::Anthropic::RateLimitError, /Rate limit/)
    end

    it "raises ServerError on 529 overload", :vcr do
      session = Session.create!(name: "vcr-529")
      shell = ShellSession.new(session_id: session.id)
      allow(shell).to receive(:pwd).and_return("/home/test/anima")
      registry = Tools::Registry.new(context: {shell_session: shell, session: session})
      AgentLoop::STANDARD_TOOLS.each { |t| registry.register(t) }

      expect {
        real_provider.create_message(
          model: "claude-opus-4-6",
          messages: [{role: "user", content: "Hey, how are you doing today?"}],
          max_tokens: 8192,
          tools: registry.schemas,
          system: session.system_prompt
        )
      }.to raise_error(Providers::Anthropic::ServerError, /server error \(529\)/)
    ensure
      shell&.finalize
    end

    it "raises ServerError on 500 server error", :vcr do
      expect {
        provider.create_message(
          model: "claude-sonnet-4-20250514",
          messages: [{role: "user", content: "Hi"}],
          max_tokens: 8192
        )
      }.to raise_error(Providers::Anthropic::ServerError, /server error/)
    end
  end

  describe "#count_tokens" do
    it "sends a request to the token counting endpoint", :vcr do
      result = real_provider.count_tokens(
        model: "claude-sonnet-4-20250514",
        messages: [{role: "user", content: "Hello"}]
      )

      expect(result).to be_a(Integer)
    end

    it "wraps system prompt in array format with OAuth passphrase", :vcr do
      result = real_provider.count_tokens(
        model: "claude-sonnet-4-20250514",
        messages: [{role: "user", content: "Hi"}],
        system: "You are helpful"
      )

      expect(result).to be_a(Integer)
    end

    it "raises Error on invalid model", :vcr do
      expect {
        real_provider.count_tokens(
          model: "bad-model",
          messages: [{role: "user", content: "Hi"}]
        )
      }.to raise_error(Providers::Anthropic::Error)
    end
  end

  describe "#validate_credentials!" do
    it "returns true on 200", vcr: "anthropic/models_200" do
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

    it "raises RateLimitError on 429", vcr: "anthropic/models_429" do
      expect { provider.validate_credentials! }
        .to raise_error(Providers::Anthropic::RateLimitError)
    end
  end

  describe "#wrap_system_prompt!" do
    let(:passphrase_block) { {type: "text", text: described_class::OAUTH_PASSPHRASE} }
    let(:cache_control) { {type: "ephemeral"} }

    it "always includes the passphrase as the first block" do
      options = {system: "You are helpful"}
      provider.send(:wrap_system_prompt!, options)

      expect(options[:system]).to be_an(Array)
      expect(options[:system].first).to include(type: "text", text: described_class::OAUTH_PASSPHRASE)
    end

    it "appends the caller's system prompt as the second block" do
      options = {system: "You are helpful"}
      provider.send(:wrap_system_prompt!, options)

      expect(options[:system].last).to include(type: "text", text: "You are helpful")
      expect(options[:system].length).to eq(2)
    end

    it "produces a single-element array when no system prompt is provided" do
      options = {}
      provider.send(:wrap_system_prompt!, options)

      expect(options[:system].length).to eq(1)
      expect(options[:system].first).to include(type: "text", text: described_class::OAUTH_PASSPHRASE)
    end

    it "annotates the last block with cache_control" do
      options = {system: "You are helpful"}
      provider.send(:wrap_system_prompt!, options)

      expect(options[:system].last[:cache_control]).to eq(cache_control)
    end

    it "annotates passphrase block when no system prompt is provided" do
      options = {}
      provider.send(:wrap_system_prompt!, options)

      expect(options[:system].first[:cache_control]).to eq(cache_control)
    end

    it "does not annotate the passphrase block when a system prompt is present" do
      options = {system: "You are helpful"}
      provider.send(:wrap_system_prompt!, options)

      expect(options[:system].first).not_to have_key(:cache_control)
    end
  end

  describe "#annotate_tools_for_caching!" do
    let(:cache_control) { {type: "ephemeral"} }

    it "adds cache_control to the last tool definition" do
      tools = [
        {name: "tool_a", description: "A"},
        {name: "tool_b", description: "B"}
      ]
      options = {tools: tools}
      provider.send(:annotate_tools_for_caching!, options)

      expect(tools.last[:cache_control]).to eq(cache_control)
    end

    it "does not annotate earlier tools" do
      tools = [
        {name: "tool_a", description: "A"},
        {name: "tool_b", description: "B"}
      ]
      options = {tools: tools}
      provider.send(:annotate_tools_for_caching!, options)

      expect(tools.first).not_to have_key(:cache_control)
    end

    it "does nothing when tools are nil" do
      options = {}
      expect { provider.send(:annotate_tools_for_caching!, options) }.not_to raise_error
    end

    it "does nothing when tools are empty" do
      options = {tools: []}
      provider.send(:annotate_tools_for_caching!, options)

      expect(options[:tools]).to eq([])
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

  describe "ApiResponse" do
    let(:body) { {"content" => [{"type" => "text", "text" => "Hello"}], "usage" => {"input_tokens" => 10}} }
    let(:api_metrics) { {"rate_limits" => {"5h_utilization" => 0.25}, "usage" => body["usage"]} }
    let(:response) { Providers::Anthropic::ApiResponse.new(body: body, api_metrics: api_metrics) }

    it "delegates [] to body" do
      expect(response["content"]).to eq(body["content"])
    end

    it "delegates dig to body" do
      expect(response.dig("content", 0, "text")).to eq("Hello")
    end

    it "delegates fetch to body" do
      expect(response.fetch("usage")).to eq(body["usage"])
    end

    it "delegates key? to body" do
      expect(response.key?("content")).to be true
      expect(response.key?("missing")).to be false
    end

    it "provides api_metrics accessor" do
      expect(response.api_metrics).to eq(api_metrics)
    end

    it "returns body from to_h" do
      expect(response.to_h).to eq(body)
    end
  end

  describe "#extract_rate_limits" do
    let(:headers) do
      {
        "Anthropic-Ratelimit-Unified-5h-Status" => ["allowed"],
        "Anthropic-Ratelimit-Unified-5h-Reset" => ["1773954000"],
        "Anthropic-Ratelimit-Unified-5h-Utilization" => ["0.19"],
        "Anthropic-Ratelimit-Unified-7d-Status" => ["allowed_warning"],
        "Anthropic-Ratelimit-Unified-7d-Reset" => ["1773986400"],
        "Anthropic-Ratelimit-Unified-7d-Utilization" => ["0.92"]
      }
    end

    it "extracts and normalizes rate limit headers" do
      result = provider.send(:extract_rate_limits, headers)

      expect(result["5h_status"]).to eq("allowed")
      expect(result["5h_reset"]).to eq(1773954000)
      expect(result["5h_utilization"]).to eq(0.19)
      expect(result["7d_status"]).to eq("allowed_warning")
      expect(result["7d_reset"]).to eq(1773986400)
      expect(result["7d_utilization"]).to eq(0.92)
    end

    it "returns empty hash when headers are nil" do
      expect(provider.send(:extract_rate_limits, nil)).to eq({})
    end

    it "handles missing headers gracefully" do
      partial_headers = {"Anthropic-Ratelimit-Unified-5h-Status" => ["allowed"]}
      result = provider.send(:extract_rate_limits, partial_headers)

      expect(result["5h_status"]).to eq("allowed")
      expect(result["5h_utilization"]).to be_nil
    end
  end

  describe "#create_message with include_metrics: true", :vcr do
    it "returns ApiResponse wrapper with metrics" do
      response = real_provider.create_message(
        model: "claude-sonnet-4-20250514",
        messages: [{role: "user", content: "Say OK"}],
        max_tokens: 10,
        include_metrics: true
      )

      expect(response).to be_a(Providers::Anthropic::ApiResponse)
      expect(response["content"]).to be_an(Array)
      expect(response.api_metrics).to be_a(Hash)
      expect(response.api_metrics["usage"]).to include("input_tokens", "output_tokens")
      expect(response.api_metrics["rate_limits"]).to be_a(Hash)
    end
  end
end
