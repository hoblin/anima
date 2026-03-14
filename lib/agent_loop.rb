# frozen_string_literal: true

# Orchestrates the LLM agent loop: accepts user input, runs the tool-use
# cycle via {LLM::Client}, and emits events through {Events::Bus}.
#
# Extracted from {TUI::Screens::Chat} so the same agent logic can run from
# the TUI, a background job, or an Action Cable channel.
#
# @note Not thread-safe. Callers must serialize concurrent calls to {#process}
#   (e.g. TUI uses a loading flag, future callers should use session-level locks).
#
# @example Basic usage
#   loop = AgentLoop.new(session: session)
#   loop.process("What files are in the current directory?")
#   loop.finalize
#
# @example With dependency injection (testing)
#   loop = AgentLoop.new(session: session, client: mock_client, registry: mock_registry)
#   loop.process("hello")
#
# @example Background job usage (retry-safe)
#   loop = AgentLoop.new(session: session)
#   loop.run  # processes persisted session messages without emitting UserMessage
#   loop.finalize
class AgentLoop
  # @return [Session] the conversation session this loop operates on
  attr_reader :session

  # @param session [Session] the conversation session
  # @param shell_session [ShellSession, nil] injectable persistent shell;
  #   created automatically if not provided
  # @param client [LLM::Client, nil] injectable LLM client;
  #   created lazily on first {#process} call if not provided
  # @param registry [Tools::Registry, nil] injectable tool registry;
  #   built lazily on first {#process} call if not provided
  def initialize(session:, shell_session: nil, client: nil, registry: nil)
    @session = session
    @shell_session = shell_session || ShellSession.new(session_id: session.id)
    @client = client
    @registry = registry
  end

  # Runs the agent loop for a single user input.
  #
  # Emits {Events::UserMessage} immediately, then delegates to {#run}.
  # On error emits {Events::AgentMessage} with the error text.
  #
  # @param input [String] raw user input
  # @return [String, nil] the agent's response text, or nil for blank input
  def process(input)
    text = input.to_s.strip
    return if text.empty?

    Events::Bus.emit(Events::UserMessage.new(content: text, session_id: @session.id))
    run
  rescue => error
    error_message = "#{error.class}: #{error.message}"
    Events::Bus.emit(Events::AgentMessage.new(content: error_message, session_id: @session.id))
    error_message
  end

  # Runs the LLM tool-use loop on persisted session messages.
  #
  # Unlike {#process}, does not emit {Events::UserMessage} and lets errors
  # propagate — designed for callers like {AgentRequestJob} that handle
  # retries and need errors to bubble up.
  #
  # @return [String] the agent's response text
  # @raise [Providers::Anthropic::TransientError] on retryable network/server errors
  # @raise [Providers::Anthropic::AuthenticationError] on auth failures
  def run
    @client ||= LLM::Client.new
    @registry ||= build_tool_registry

    messages = @session.messages_for_llm
    options = {}
    options[:system] = @session.system_prompt if @session.system_prompt

    response = @client.chat_with_tools(messages, registry: @registry, session_id: @session.id, **options)
    Events::Bus.emit(Events::AgentMessage.new(content: response, session_id: @session.id))
    response
  end

  # Clean up the underlying {ShellSession} PTY and resources.
  # Safe to call multiple times — subsequent calls are no-ops.
  def finalize
    @shell_session&.finalize
  end

  # Tool classes available to all sessions by default.
  # @return [Array<Class<Tools::Base>>]
  STANDARD_TOOLS = [Tools::Bash, Tools::Read, Tools::Write, Tools::Edit, Tools::WebGet].freeze

  # Name-to-class mapping for tool restriction validation and registry building.
  # @return [Hash{String => Class<Tools::Base>}]
  STANDARD_TOOLS_BY_NAME = STANDARD_TOOLS.index_by(&:tool_name).freeze

  private

  # Builds the tool registry appropriate for this session type.
  # Main sessions get standard tools + spawn_subagent.
  # Sub-agent sessions get granted standard tools + return_result (not spawn_subagent).
  # Sub-agents cannot spawn sub-agents (no recursive nesting).
  # When {Session#granted_tools} is nil, all standard tools are granted.
  #
  # @return [Tools::Registry] registry with available tools
  def build_tool_registry
    context = {shell_session: @shell_session, session: @session}
    registry = Tools::Registry.new(context: context)

    granted_standard_tools.each { |tool| registry.register(tool) }

    if @session.sub_agent?
      registry.register(Tools::ReturnResult)
    else
      registry.register(Tools::SpawnSubagent)
    end

    registry
  end

  # Standard tools available to this session.
  # Returns all when {Session#granted_tools} is nil (no restriction).
  # Returns only matching tools when granted_tools is an array.
  #
  # @return [Array<Class<Tools::Base>>] tool classes to register
  def granted_standard_tools
    return STANDARD_TOOLS unless @session.granted_tools

    @session.granted_tools.filter_map { |name| STANDARD_TOOLS_BY_NAME[name] }
  end
end
