# frozen_string_literal: true

require "vcr"

VCR.configure do |config|
  config.cassette_library_dir = "spec/cassettes"
  config.hook_into :webmock
  config.configure_rspec_metadata!

  config.filter_sensitive_data("<ANTHROPIC_API_KEY>") do
    CredentialStore.read("anthropic", "subscription_token")
  rescue
    "sk-ant-oat01-filtered"
  end

  # :new_episodes in dev (record new requests, replay existing), :none in CI (all must be pre-recorded).
  config.default_cassette_options = {
    record: ENV["CI"] ? :none : :new_episodes,
    match_requests_on: [:method, :uri, :body]
  }
end
