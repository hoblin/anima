# frozen_string_literal: true

module LLM
  # Convenience layer over {Providers::Anthropic} for phantom sessions
  # (Mneme, Melete, Mneme::L2Runner) that need a multi-round tool-use
  # loop driven from plain Ruby objects rather than the main drain
  # pipeline.
  #
  # The main agent loop does NOT use this class — {DrainJob} talks to
  # the provider directly and emits {Events::LLMResponded} for
  # {Events::Subscribers::LLMResponseHandler} to process. The tool loop
  # here is deliberately minimal: no events, no AASM transitions, no
  # interrupt handling — phantom sessions don't interact with those
  # machineries.
  #
  # @example
  #   registry = Tools::Registry.new
  #   registry.register(Tools::SaveSnapshot)
  #   client.chat_with_tools(messages, registry: registry)
  class Client
    # Synthetic tool_result text shown when a tool run is aborted by the
    # user's Escape press. Mirrored into the interrupt subsystem so both
    # the bash tool and any future interrupt handler share the phrasing.
    INTERRUPT_MESSAGE = "Your human wants your attention"

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

    # Runs a minimal multi-round tool-use cycle: call the LLM, execute
    # any requested tools, feed results back, repeat until the LLM
    # produces a final text response.
    #
    # Intended for phantom sessions (Mneme, Melete). No events are
    # emitted and no persistence happens — the caller is responsible
    # for capturing whatever state the tool runs produce.
    #
    # @param messages [Array<Hash>] conversation messages in Anthropic format
    # @param registry [Tools::Registry] registered tools to make available
    # @param options [Hash] additional API parameters (e.g. +system:+)
    # @return [Hash] +:text+ (String) and +:api_metrics+ (Hash)
    # @raise [Providers::Anthropic::Error] on API errors
    def chat_with_tools(messages, registry:, **options)
      messages = messages.dup
      rounds = 0
      last_api_metrics = nil

      loop do
        rounds += 1
        max_rounds = Anima::Settings.max_tool_rounds
        if rounds > max_rounds
          return {text: "[Tool loop exceeded #{max_rounds} rounds — halting]", api_metrics: last_api_metrics}
        end

        response = provider.create_message(
          model: model,
          messages: messages,
          max_tokens: max_tokens,
          tools: registry.schemas,
          include_metrics: true,
          **options
        )

        last_api_metrics = response.api_metrics if response.respond_to?(:api_metrics)

        log(:debug, "stop_reason=#{response["stop_reason"]} content_types=#{(response["content"] || []).map { |b| b["type"] }.join(",")}")

        if response["stop_reason"] == "tool_use"
          tool_results = execute_tools(response, registry)
          messages += [
            {role: "assistant", content: response["content"]},
            {role: "user", content: tool_results}
          ]
        else
          return {text: extract_text(response), api_metrics: last_api_metrics}
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

    # Executes every +tool_use+ block from the response and returns
    # matching +tool_result+ blocks. Always emits a result — a missing
    # result permanently corrupts the Anthropic conversation history.
    def execute_tools(response, registry)
      extract_tool_uses(response).map { |tool_use| execute_single_tool(tool_use, registry) }
    end

    def execute_single_tool(tool_use, registry)
      name = tool_use["name"]
      id = tool_use["id"] || SecureRandom.uuid
      input = tool_use["input"] || {}

      log(:debug, "tool_call: #{name}(#{input.to_json})")

      result = registry.execute(name, input)
      result = ToolDecorator.call(name, result)
      result_content = format_tool_result(result)
      result_content = truncate_tool_result(result_content, registry, name)

      log(:debug, "tool_result: #{name} → #{result_content.to_s.truncate(200)}")

      {type: "tool_result", tool_use_id: id, content: result_content}
    rescue => error
      error_detail = "#{error.class}: #{error.message}"
      Rails.logger.error("Tool #{name} raised #{error_detail}")
      {type: "tool_result", tool_use_id: id, content: format_tool_result(error: error_detail)}
    end

    def log(level, message)
      return unless @logger
      @logger.public_send(level, message)
    end

    def format_tool_result(result)
      result.is_a?(Hash) ? result.to_json : result.to_s
    end

    def truncate_tool_result(content, registry, tool_name)
      threshold = registry.truncation_threshold(tool_name)
      return content unless threshold

      lines = Tools::ResponseTruncator::HEAD_LINES
      reason = "#{tool_name} output displays first/last #{lines} lines"
      Tools::ResponseTruncator.truncate(content, threshold: threshold, reason: reason)
    end
  end
end
