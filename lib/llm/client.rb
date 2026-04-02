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
    # Synthetic tool_result when a tool is skipped because the human pressed Escape.
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
    # "Your human wants your attention" results and the loop exits without another LLM call.
    #
    # @param messages [Array<Hash>] conversation messages in Anthropic format
    # @param registry [Tools::Registry] registered tools to make available
    # @param session_id [Integer, String] session ID for emitted events
    # @param first_response [Hash, nil] pre-fetched first API response from
    #   {AgentLoop#deliver!}. Skips the first API call when provided so
    #   the Bounce Back transaction doesn't duplicate work.
    # @param between_rounds [#call, nil] callback invoked after each tool
    #   round completes, before the next LLM request. Must return an
    #   +Array<String>+ of message contents to inject (e.g. promoted
    #   pending messages). Injected as +text+ blocks alongside
    #   +tool_result+ blocks so the LLM sees them in the next round.
    # @param options [Hash] additional API parameters (e.g. +system:+)
    # @return [Hash, nil] +:text+ (String) and +:api_metrics+ (Hash), or nil when interrupted
    # @raise [Providers::Anthropic::Error] on API errors
    def chat_with_tools(messages, registry:, session_id:, first_response: nil, between_rounds: nil, **options)
      messages = messages.dup
      rounds = 0
      last_api_metrics = nil

      loop do
        rounds += 1
        max_rounds = Anima::Settings.max_tool_rounds
        if rounds > max_rounds
          return {text: "[Tool loop exceeded #{max_rounds} rounds — halting]", api_metrics: last_api_metrics}
        end

        response = if first_response && rounds == 1
          first_response
        else
          broadcast_session_state(session_id, "llm_generating")
          provider.create_message(
            model: model,
            messages: messages,
            max_tokens: max_tokens,
            tools: registry.schemas,
            include_metrics: true,
            **options
          )
        end

        # Capture api_metrics from ApiResponse wrapper (nil for pre-fetched first_response)
        last_api_metrics = response.api_metrics if response.respond_to?(:api_metrics)
        log_cache_metrics(last_api_metrics)

        log(:debug, "stop_reason=#{response["stop_reason"]} content_types=#{(response["content"] || []).map { |b| b["type"] }.join(",")}")

        if response["stop_reason"] == "tool_use"
          tool_results = execute_tools(response, registry, session_id)
          promoted = promote_between_rounds(between_rounds)

          # Dual injection: user messages go as text blocks within the current
          # tool_results turn (same speaker); sub-agent messages append as
          # separate assistant→user turn pairs (distinct tool invocations).
          promoted[:texts].each { |text| tool_results << {type: "text", text: text} }

          messages += [
            {role: "assistant", content: response["content"]},
            {role: "user", content: tool_results}
          ]

          messages.concat(promoted[:pairs])

          return nil if handle_interrupt!(session_id)
        else
          # Discard the text response if the user pressed Escape while
          # the API was generating it. Without this check the interrupt
          # flag set during the blocking API call would be silently
          # cleared by the ensure block in AgentRequestJob.
          return nil if handle_interrupt!(session_id)

          return {text: extract_text(response), api_metrics: last_api_metrics}
        end
      end
    end

    private

    # Invokes the between_rounds callback and returns promoted messages
    # split by injection strategy.
    #
    # @param between_rounds [#call, nil] callback returning
    #   +{texts: Array<String>, pairs: Array<Hash>}+
    # @return [Hash{Symbol => Array}] +:texts+ for user messages (text blocks
    #   in current tool_results), +:pairs+ for sub-agent messages (separate
    #   conversation turns)
    def promote_between_rounds(between_rounds)
      return {texts: [], pairs: []} unless between_rounds
      between_rounds.call
    end

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
      interrupted = false

      tool_uses.each_with_index do |tool_use, index|
        # Check-only here; clearing happens in handle_interrupt! after the loop
        interrupted ||= interrupt_requested?(session_id)
        if interrupted
          remaining = tool_uses[index..]
          results.concat(interrupt_remaining_tools(remaining, session_id)) if remaining&.any?
          break
        end
        results << execute_single_tool(tool_use, registry, session_id)
      end

      results
    end

    # Creates synthetic "Your human wants your attention" results for all tools in the list.
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
    #
    # Falls back to SecureRandom.uuid when Anthropic omits the tool_use id,
    # ensuring the ToolCall/ToolResponse pair always shares a valid identifier.
    def execute_single_tool(tool_use, registry, session_id)
      name = tool_use["name"]
      id = tool_use["id"] || SecureRandom.uuid
      input = tool_use["input"] || {}
      timeout = input["timeout"] || Anima::Settings.tool_timeout

      log(:debug, "tool_call: #{name}(#{input.to_json})")

      broadcast_session_state(session_id, "tool_executing", tool: name)

      Events::Bus.emit(Events::ToolCall.new(
        content: "Calling #{name}", tool_name: name,
        tool_input: input, tool_use_id: id, timeout: timeout,
        session_id: session_id
      ))

      result = registry.execute(name, input)
      result = ToolDecorator.call(name, result)
      result_content = format_tool_result(result)
      result_content = truncate_tool_result(result_content, registry, name)
      log(:debug, "tool_result: #{name} → #{result_content.to_s.truncate(200)}")

      Events::Bus.emit(Events::ToolResponse.new(
        content: result_content, tool_name: name, tool_use_id: id,
        success: !result.is_a?(Hash) || !result.key?(:error),
        session_id: session_id
      ))

      {type: "tool_result", tool_use_id: id, content: result_content}
    rescue => error
      error_detail = "#{error.class}: #{error.message}"
      Rails.logger.error("Tool #{name} raised #{error_detail}")
      error_content = format_tool_result(error: error_detail)

      # Emission can fail (e.g. encoding errors in ActionCable/SQLite),
      # but losing the tool_result would permanently corrupt the session.
      begin
        Events::Bus.emit(Events::ToolResponse.new(
          content: error_content, tool_name: name, tool_use_id: id,
          success: false, session_id: session_id
        ))
      rescue => emit_error
        Rails.logger.error("ToolResponse emission failed: #{emit_error.class}: #{emit_error.message}")
      end

      {type: "tool_result", tool_use_id: id, content: error_content}
    end

    # Creates a synthetic "Your human wants your attention" result for a tool that was not
    # executed due to user interrupt. Emits both ToolCall and ToolResponse
    # events so the TUI shows the interrupted tool in the event stream.
    #
    # @param tool_use [Hash] Anthropic tool_use content block
    # @param session_id [Integer, String] session ID for events
    # @return [Hash] tool_result content block
    def interrupt_tool(tool_use, session_id)
      name = tool_use["name"]
      id = tool_use["id"] || SecureRandom.uuid
      input = tool_use["input"] || {}

      Events::Bus.emit(Events::ToolCall.new(
        content: "Skipped #{name} — your human wants your attention", tool_name: name,
        tool_input: input, tool_use_id: id, session_id: session_id
      ))

      Events::Bus.emit(Events::ToolResponse.new(
        content: INTERRUPT_MESSAGE, tool_name: name, tool_use_id: id,
        success: false, session_id: session_id
      ))

      {type: "tool_result", tool_use_id: id, content: INTERRUPT_MESSAGE}
    end

    # Checks whether the session has a pending interrupt flag.
    #
    # @param session_id [Integer, String] session to check
    # @return [Boolean] true when interrupt is pending
    def interrupt_requested?(session_id)
      Session.where(id: session_id, interrupt_requested: true).exists?
    end

    # Atomically checks for a pending interrupt and clears it in one query.
    # Used at loop boundaries (after tools, before LLM text return) to
    # short-circuit the agent loop when the user presses Escape.
    #
    # @param session_id [Integer, String] session to check
    # @return [Boolean] true when interrupt was detected and cleared
    def handle_interrupt!(session_id)
      Session.where(id: session_id, interrupt_requested: true)
        .update_all(interrupt_requested: false) > 0
    end

    # Broadcasts a session state transition to all subscribed clients.
    # Delegates to {Session#broadcast_session_state} which handles both
    # the session's own stream and the parent's stream for HUD updates.
    #
    # @param session_id [Integer, String] session to broadcast for
    # @param state [String] one of "idle", "llm_generating", "tool_executing", "interrupting"
    # @param tool [String, nil] tool name when state is "tool_executing"
    # @return [void]
    def broadcast_session_state(session_id, state, tool: nil)
      Session.find_by(id: session_id)&.broadcast_session_state(state, tool: tool)
    end

    def log(level, message)
      return unless @logger

      @logger.public_send(level, message)
    end

    # Logs cache hit/miss/creation token counts when present in API metrics.
    #
    # @param api_metrics [Hash, nil] metrics hash with "usage" key
    # @return [void]
    def log_cache_metrics(api_metrics)
      usage = api_metrics&.dig("usage")
      return unless usage

      cache_read = usage["cache_read_input_tokens"].to_i
      cache_create = usage["cache_creation_input_tokens"].to_i
      return if cache_read.zero? && cache_create.zero?

      input = usage["input_tokens"].to_i
      total = input + cache_read + cache_create
      hit_pct = (total > 0) ? (cache_read * 100.0 / total).round(1) : 0.0
      log(:debug, "cache: read=#{cache_read} create=#{cache_create} uncached=#{input} hit=#{hit_pct}%")
    end

    def format_tool_result(result)
      result.is_a?(Hash) ? result.to_json : result.to_s
    end

    # Applies head+tail truncation when a tool result exceeds the tool's
    # configured character threshold. Skips tools that opt out (e.g. read).
    def truncate_tool_result(content, registry, tool_name)
      threshold = registry.truncation_threshold(tool_name)
      return content unless threshold

      lines = Tools::ResponseTruncator::HEAD_LINES
      reason = "#{tool_name} output displays first/last #{lines} lines"
      Tools::ResponseTruncator.truncate(content, threshold: threshold, reason: reason)
    end
  end
end
