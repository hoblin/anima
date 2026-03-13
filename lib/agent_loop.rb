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
    response = @client.chat_with_tools(messages, registry: @registry, session_id: @session.id)
    Events::Bus.emit(Events::AgentMessage.new(content: response, session_id: @session.id))
    response
  end

  # Clean up the underlying {ShellSession} PTY and resources.
  # Safe to call multiple times — subsequent calls are no-ops.
  def finalize
    @shell_session&.finalize
  end

  private

  # Builds the default tool registry with all available tools.
  # @return [Tools::Registry] registry with all available tools
  def build_tool_registry
    registry = Tools::Registry.new(context: {shell_session: @shell_session})
    registry.register(Tools::Bash)
    registry.register(Tools::Read)
    registry.register(Tools::Write)
    registry.register(Tools::Edit)
    registry.register(Tools::WebGet)
    registry
  end
end
