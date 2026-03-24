# frozen_string_literal: true

require "vcr"

VCR.configure do |config|
  config.cassette_library_dir = "spec/cassettes"
  config.hook_into :webmock
  config.configure_rspec_metadata!
  config.ignore_localhost = true
  config.allow_http_connections_when_no_cassette = false

  config.filter_sensitive_data("<ANTHROPIC_API_KEY>") do
    CredentialStore.read("anthropic", "subscription_token") || "sk-ant-oat01-filtered"
  end

  # Filter headers that identify the account or track sessions.
  config.filter_sensitive_data("<AUTHORIZATION>") do |interaction|
    interaction.request.headers["Authorization"]&.first
  end

  config.filter_sensitive_data("<ANTHROPIC_ORG_ID>") do |interaction|
    interaction.response.headers["Anthropic-Organization-Id"]&.first
  end

  config.filter_sensitive_data("<CLOUDFLARE_COOKIE>") do |interaction|
    interaction.response.headers["Set-Cookie"]&.first
  end

  config.filter_sensitive_data("<REQUEST_ID>") do |interaction|
    interaction.response.headers["Request-Id"]&.first
  end

  config.filter_sensitive_data("<CF_RAY>") do |interaction|
    interaction.response.headers["Cf-Ray"]&.first
  end

  # LLM responses may contain special characters or binary data.
  config.preserve_exact_body_bytes do |http_message|
    http_message.body.encoding.name == "ASCII-8BIT" ||
      !http_message.body.valid_encoding?
  end

  config.default_cassette_options = {
    record: ENV["CI"] ? :none : :new_episodes,
    match_requests_on: [:method, :uri, :body]
  }
end
