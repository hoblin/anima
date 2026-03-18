# frozen_string_literal: true

require "vcr"

VCR.configure do |config|
  config.cassette_library_dir = "spec/cassettes"
  config.hook_into :webmock
  config.configure_rspec_metadata!
  config.ignore_localhost = true

  config.filter_sensitive_data("<ANTHROPIC_API_KEY>") do
    CredentialStore.read("anthropic", "subscription_token") || "sk-ant-oat01-filtered"
  end

  # Filter Authorization header directly so new cassettes never leak tokens.
  config.filter_sensitive_data("<AUTHORIZATION>") do |interaction|
    interaction.request.headers["Authorization"]&.first
  end

  # LLM responses may contain special characters or binary data.
  config.preserve_exact_body_bytes do |http_message|
    http_message.body.encoding.name == "ASCII-8BIT" ||
      !http_message.body.valid_encoding?
  end

  # :new_episodes in dev (record new requests, replay existing), :none in CI (all must be pre-recorded).
  # Override with VCR_MODE=rec to force re-recording: VCR_MODE=rec bundle exec rspec spec/path:42
  record_mode = if /rec/i.match?(ENV["VCR_MODE"])
    :all
  elsif ENV["CI"]
    :none
  else
    :new_episodes
  end

  config.default_cassette_options = {
    record: record_mode,
    match_requests_on: [:method, :uri, :body]
  }
end
