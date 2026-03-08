# frozen_string_literal: true

module LLM
  # Thin convenience layer over {Providers::Anthropic} for sending messages
  # and extracting assistant response text. No streaming, no context assembly —
  # just send a messages array and get a response back.
  #
  # @example Basic usage
  #   client = LLM::Client.new
  #   client.chat([{role: "user", content: "Say hello"}])
  #   # => "Hello! How can I help you today?"
  #
  # @example With custom model and system prompt
  #   client = LLM::Client.new(model: "claude-haiku-4-5-20251001", max_tokens: 4096)
  #   client.chat(
  #     [{role: "user", content: "Summarize this"}],
  #     system: "You are a concise summarizer"
  #   )
  class Client
    DEFAULT_MODEL = "claude-sonnet-4-20250514"
    DEFAULT_MAX_TOKENS = 8192

    # @return [Providers::Anthropic] the underlying API provider
    attr_reader :provider

    # @return [String] the model identifier used for API calls
    attr_reader :model

    # @return [Integer] maximum tokens in the response
    attr_reader :max_tokens

    # @param model [String] Anthropic model identifier
    # @param max_tokens [Integer] maximum tokens in the response
    # @param provider [Providers::Anthropic, nil] injectable provider instance;
    #   defaults to a new {Providers::Anthropic} using credentials
    def initialize(model: DEFAULT_MODEL, max_tokens: DEFAULT_MAX_TOKENS, provider: nil)
      @provider = build_provider(provider)
      @model = model
      @max_tokens = max_tokens
    end

    # Send messages to the LLM and return the assistant's text response.
    #
    # @param messages [Array<Hash>] conversation messages, each with +:role+ and +:content+
    # @param options [Hash] additional API parameters (e.g. +system:+, +temperature:+)
    # @return [String] the assistant's response text
    # @raise [Providers::Anthropic::Error] on API errors
    # @raise [Providers::Anthropic::AuthenticationError] on auth failures
    def chat(messages, **options)
      response = provider.create_message(
        model: model,
        messages: messages,
        max_tokens: max_tokens,
        **options
      )

      extract_text(response)
    end

    private

    def build_provider(provider)
      provider || Providers::Anthropic.new
    end

    def extract_text(response)
      content = response["content"] || []

      content
        .select { |block| block["type"] == "text" }
        .map { |block| block["text"] }
        .join
    end
  end
end
