# frozen_string_literal: true

# Orchestrates the LLM agent loop: accepts user input, runs the tool-use
# cycle via {LLM::Client}, and emits events through {Events::Bus}.
#
# Extracted from {TUI::Screens::Chat} so the same agent logic can run from
# the TUI, a background job, or an Action Cable channel.
#
# @example Basic usage
#   loop = AgentLoop.new(session: session)
#   loop.process("What files are in the current directory?")
#   loop.finalize
class AgentLoop
  # @return [Session] the conversation session this loop operates on
  attr_reader :session

  # @param session [Session] the conversation session
  # @param shell_session [ShellSession, nil] injectable persistent shell;
  #   created automatically if not provided
  # @param client [LLM::Client, nil] injectable LLM client;
  #   created lazily on first {#process} call if not provided
  def initialize(session:, shell_session: nil, client: nil)
    @session = session
    @session_id = session.id
    @shell_session = shell_session || ShellSession.new(session_id: @session_id)
    @client = client
    @registry = nil
  end

  # Runs the agent loop for a single user input.
  #
  # Emits {Events::UserMessage} immediately, then enters the LLM tool-use
  # loop. On completion emits {Events::AgentMessage} with the final response.
  # On error emits {Events::AgentMessage} with the error text.
  #
  # @param input [String] raw user input
  # @return [String, nil] the agent's response text, or nil for blank input
  def process(input)
    text = input.to_s.strip
    return if text.empty?

    Events::Bus.emit(Events::UserMessage.new(content: text, session_id: @session_id))

    @client ||= LLM::Client.new
    @registry ||= build_tool_registry

    messages = @session.messages_for_llm
    response = @client.chat_with_tools(messages, registry: @registry, session_id: @session_id)
    Events::Bus.emit(Events::AgentMessage.new(content: response, session_id: @session_id))
    response
  rescue => error
    error_message = "Error: #{error.message}"
    Events::Bus.emit(Events::AgentMessage.new(content: error_message, session_id: @session_id))
    error_message
  end

  # Clean up the underlying {ShellSession} PTY and resources.
  def finalize
    @shell_session&.finalize
  end

  private

  def build_tool_registry
    registry = Tools::Registry.new(context: {shell_session: @shell_session})
    registry.register(Tools::WebGet)
    registry.register(Tools::Bash)
    registry
  end
end
