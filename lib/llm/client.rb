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
    # Synthetic tool_result message when a tool is skipped due to user interrupt.
    INTERRUPT_MESSAGE = "Stopped by user"

    # @return [Providers::Anthropic] the underlying API provider
    attr_reader :provider

    # @return [String] the model identifier used for API calls
    attr_reader :model

    # @return [Integer] maximum tokens in the response
    attr_reader :max_tokens

    # @param model [String] Anthropic model identifier (default from Settings)
    # @param max_tokens [Integer] maximum tokens in the response (default from Settings)
    # @param provider [Providers::Anthropic, nil] injectable provider instance;
    #   defaults to a new {Providers::Anthropic} using credentials
    # @param logger [Logger, nil] optional logger for tool call tracing
    def initialize(model: Anima::Settings.model, max_tokens: Anima::Settings.max_tokens, provider: nil, logger: nil)
      @provider = build_provider(provider)
      @model = model
      @max_tokens = max_tokens
      @logger = logger
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
    # When the user interrupts via Escape, remaining tools receive synthetic
    # "Stopped by user" results and the loop exits without another LLM call.
    #
    # @param messages [Array<Hash>] conversation messages in Anthropic format
    # @param registry [Tools::Registry] registered tools to make available
    # @param session_id [Integer, String] session ID for emitted events
    # @param first_response [Hash, nil] pre-fetched first API response from
    #   {AgentLoop#deliver!}. Skips the first API call when provided so
    #   the Bounce Back transaction doesn't duplicate work.
    # @param options [Hash] additional API parameters (e.g. +system:+)
    # @return [String, nil] the assistant's final text response, or nil when interrupted
    # @raise [Providers::Anthropic::Error] on API errors
    def chat_with_tools(messages, registry:, session_id:, first_response: nil, **options)
      messages = messages.dup
      rounds = 0

      loop do
        rounds += 1
        max_rounds = Anima::Settings.max_tool_rounds
        if rounds > max_rounds
          return "[Tool loop exceeded #{max_rounds} rounds — halting]"
        end

        response = if first_response && rounds == 1
          first_response
        else
          provider.create_message(
            model: model,
            messages: messages,
            max_tokens: max_tokens,
            tools: registry.schemas,
            **options
          )
        end

        log(:debug, "stop_reason=#{response["stop_reason"]} content_types=#{(response["content"] || []).map { |b| b["type"] }.join(",")}")

        if response["stop_reason"] == "tool_use"
          tool_results = execute_tools(response, registry, session_id)

          messages += [
            {role: "assistant", content: response["content"]},
            {role: "user", content: tool_results}
          ]

          if interrupted?(session_id)
            clear_interrupt!(session_id)
            return nil
          end
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
    # Checks for user interrupt between tools — remaining tools receive
    # synthetic results to satisfy the Anthropic API's tool_use/tool_result
    # pairing requirement (a missing result permanently breaks the conversation).
    #
    # @param response [Hash] Anthropic API response with tool_use content blocks
    # @param registry [Tools::Registry] tool registry for dispatch
    # @param session_id [Integer, String] session ID for events
    # @return [Array<Hash>] tool_result content blocks for the next API call
    def execute_tools(response, registry, session_id)
      tool_uses = extract_tool_uses(response)
      results = []

      tool_uses.each_with_index do |tool_use, index|
        if interrupted?(session_id)
          remaining = tool_uses[index..]
          results.concat(interrupt_remaining_tools(remaining, session_id)) if remaining&.any?
          break
        end
        results << execute_single_tool(tool_use, registry, session_id)
      end

      results
    end

    # Creates synthetic "Stopped by user" results for all tools in the list.
    #
    # @param tool_uses [Array<Hash>] remaining tool_use content blocks
    # @param session_id [Integer, String] session ID for events
    # @return [Array<Hash>] tool_result content blocks
    def interrupt_remaining_tools(tool_uses, session_id)
      tool_uses.map { |tool_use| interrupt_tool(tool_use, session_id) }
    end

    # Executes a single tool and always returns a tool_result — even if the
    # tool raises. Per the Anthropic tool-use protocol, every tool_use must
    # have a matching tool_result; a missing result permanently corrupts the
    # conversation history and breaks the session.
    def execute_single_tool(tool_use, registry, session_id)
      name = tool_use["name"]
      id = tool_use["id"]
      input = tool_use["input"] || {}

      log(:debug, "tool_call: #{name}(#{input.to_json})")

      Events::Bus.emit(Events::ToolCall.new(
        content: "Calling #{name}", tool_name: name,
        tool_input: input, tool_use_id: id, session_id: session_id
      ))

      result = begin
        registry.execute(name, input)
      rescue => error
        Rails.logger.error("Tool #{name} raised #{error.class}: #{error.message}")
        {error: "#{error.class}: #{error.message}"}
      end

      result_content = format_tool_result(result)
      log(:debug, "tool_result: #{name} → #{result_content.to_s.truncate(200)}")

      Events::Bus.emit(Events::ToolResponse.new(
        content: result_content, tool_name: name, tool_use_id: id,
        success: !result.is_a?(Hash) || !result.key?(:error),
        session_id: session_id
      ))

      {type: "tool_result", tool_use_id: id, content: result_content}
    end

    # Creates a synthetic "Stopped by user" result for a tool that was not
    # executed due to user interrupt. Emits both ToolCall and ToolResponse
    # events so the TUI shows the interrupted tool in the event stream.
    #
    # @param tool_use [Hash] Anthropic tool_use content block
    # @param session_id [Integer, String] session ID for events
    # @return [Hash] tool_result content block
    def interrupt_tool(tool_use, session_id)
      name = tool_use["name"]
      id = tool_use["id"]
      input = tool_use["input"] || {}

      Events::Bus.emit(Events::ToolCall.new(
        content: "Skipped #{name} (interrupted)", tool_name: name,
        tool_input: input, tool_use_id: id, session_id: session_id
      ))

      Events::Bus.emit(Events::ToolResponse.new(
        content: INTERRUPT_MESSAGE, tool_name: name, tool_use_id: id,
        success: false, session_id: session_id
      ))

      {type: "tool_result", tool_use_id: id, content: INTERRUPT_MESSAGE}
    end

    # Checks the database for a pending interrupt flag on the session.
    #
    # @param session_id [Integer, String] session to check
    # @return [Boolean] whether the session has a pending interrupt request
    def interrupted?(session_id)
      Session.where(id: session_id, interrupt_requested: true).exists?
    end

    # Clears the interrupt flag so the agent loop can continue with pending
    # messages. Also cleared by {AgentRequestJob#clear_interrupt} as a safety
    # net for unexpected exits.
    #
    # @param session_id [Integer, String] session to clear
    # @return [void]
    def clear_interrupt!(session_id)
      Session.where(id: session_id).update_all(interrupt_requested: false)
    end

    def log(level, message)
      return unless @logger

      @logger.public_send(level, message)
    end

    def format_tool_result(result)
      result.is_a?(Hash) ? result.to_json : result.to_s
    end
  end
end
