# frozen_string_literal: true

module LLM
  # Convenience layer over {Providers::Anthropic} for sending messages
  # and handling tool execution loops. Supports both simple text chat
  # and multi-turn tool calling via the Anthropic tool use protocol.
  #
  # @example Simple chat (no tools)
  #   client = LLM::Client.new
  #   client.chat([{role: "user", content: "Say hello"}])
  #   # => "Hello! How can I help you today?"
  #
  # @example Chat with tools
  #   registry = Tools::Registry.new
  #   registry.register(Tools::WebGet)
  #   client.chat_with_tools(messages, registry: registry, session_id: session.id)
  class Client
    DEFAULT_MODEL = "claude-sonnet-4-20250514"
    FAST_MODEL = "claude-haiku-4-5"
    DEFAULT_MAX_TOKENS = 8192
    MAX_TOOL_ROUNDS = 25

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

    # Send messages with tool support. Runs the full tool execution loop:
    # call LLM, execute any requested tools, feed results back, repeat
    # until the LLM produces a final text response.
    #
    # Emits {Events::ToolCall} and {Events::ToolResponse} events for each
    # tool interaction so they're persisted and visible in the event stream.
    #
    # @param messages [Array<Hash>] conversation messages in Anthropic format
    # @param registry [Tools::Registry] registered tools to make available
    # @param session_id [Integer, String] session ID for emitted events
    # @param options [Hash] additional API parameters (e.g. +system:+)
    # @return [String] the assistant's final text response
    # @raise [Providers::Anthropic::Error] on API errors
    def chat_with_tools(messages, registry:, session_id:, **options)
      messages = messages.dup
      rounds = 0

      loop do
        rounds += 1
        if rounds > MAX_TOOL_ROUNDS
          return "[Tool loop exceeded #{MAX_TOOL_ROUNDS} rounds — halting]"
        end

        response = provider.create_message(
          model: model,
          messages: messages,
          max_tokens: max_tokens,
          tools: registry.schemas,
          **options
        )

        if response["stop_reason"] == "tool_use"
          tool_results = execute_tools(response, registry, session_id)

          messages += [
            {role: "assistant", content: response["content"]},
            {role: "user", content: tool_results}
          ]
        else
          return extract_text(response)
        end
      end
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

    def extract_tool_uses(response)
      content = response["content"] || []
      content.select { |block| block["type"] == "tool_use" }
    end

    # Executes all tool_use blocks from a response, emitting events for each.
    #
    # @param response [Hash] Anthropic API response with tool_use content blocks
    # @param registry [Tools::Registry] tool registry for dispatch
    # @param session_id [Integer, String] session ID for events
    # @return [Array<Hash>] tool_result content blocks for the next API call
    def execute_tools(response, registry, session_id)
      extract_tool_uses(response).map do |tool_use|
        execute_single_tool(tool_use, registry, session_id)
      end
    end

    def execute_single_tool(tool_use, registry, session_id)
      name = tool_use["name"]
      id = tool_use["id"]
      input = tool_use["input"] || {}

      Events::Bus.emit(Events::ToolCall.new(
        content: "Calling #{name}", tool_name: name,
        tool_input: input, tool_use_id: id, session_id: session_id
      ))

      result = registry.execute(name, input)
      result_content = format_tool_result(result)

      Events::Bus.emit(Events::ToolResponse.new(
        content: result_content, tool_name: name, tool_use_id: id,
        success: !result.is_a?(Hash) || !result.key?(:error),
        session_id: session_id
      ))

      {type: "tool_result", tool_use_id: id, content: result_content}
    end

    def format_tool_result(result)
      result.is_a?(Hash) ? result.to_json : result.to_s
    end
  end
end
