# frozen_string_literal: true

# Orchestrates the LLM agent loop: accepts user input, runs the tool-use
# cycle via {LLM::Client}, and emits events through {Events::Bus}.
#
# Extracted from {TUI::Screens::Chat} so the same agent logic can run from
# the TUI, a background job, or an Action Cable channel.
#
# @note Not thread-safe. Callers must serialize concurrent access
#   (e.g. {AgentRequestJob} uses session-level processing locks).
#
# @example Basic usage
#   loop = AgentLoop.new(session: session)
#   loop.run
#   loop.finalize
#
# @example With dependency injection (testing)
#   loop = AgentLoop.new(session: session, client: mock_client, registry: mock_registry)
#   loop.run
class AgentLoop
  # @return [Session] the conversation session this loop operates on
  attr_reader :session

  # @param session [Session] the conversation session
  # @param shell_session [ShellSession, nil] injectable persistent shell;
  #   created automatically if not provided
  # @param client [LLM::Client, nil] injectable LLM client;
  #   created lazily on first {#run} call if not provided
  # @param registry [Tools::Registry, nil] injectable tool registry;
  #   built lazily on first {#run} call if not provided
  def initialize(session:, shell_session: nil, client: nil, registry: nil)
    @session = session
    @shell_session = shell_session || ShellSession.new(session_id: session.id)
    @client = client
    @registry = registry
  end

  # Makes the first LLM API call to verify delivery. Called inside the
  # Bounce Back transaction — if this raises, the user event rolls back.
  #
  # Caches the first response so the subsequent {#run} call can continue
  # from it without duplicating the API call.
  #
  # @return [void]
  # @raise [Providers::Anthropic::Error] on any LLM delivery failure
  def deliver!
    @client ||= LLM::Client.new
    @registry ||= build_tool_registry

    messages = @session.messages_for_llm
    options = build_llm_options

    @first_response = @client.provider.create_message(
      model: @client.model,
      messages: messages,
      max_tokens: @client.max_tokens,
      tools: @registry.schemas,
      **options
    )
  end

  # Runs the LLM tool-use loop on persisted session messages.
  #
  # When a cached first response exists (from {#deliver!}), continues
  # from that response without a redundant API call. Otherwise makes
  # a fresh call — used for pending message processing and the standard
  # path.
  #
  # Lets errors propagate — designed for callers like {AgentRequestJob}
  # that handle retries and need errors to bubble up.
  #
  # @return [String, nil] the agent's response text, or nil when interrupted
  # @raise [Providers::Anthropic::TransientError] on retryable network/server errors
  # @raise [Providers::Anthropic::AuthenticationError] on auth failures
  def run
    @client ||= LLM::Client.new
    @registry ||= build_tool_registry

    messages = @session.messages_for_llm
    options = build_llm_options

    first_resp = @first_response
    @first_response = nil

    between_rounds = -> { @session.promote_pending_messages! }

    result = @client.chat_with_tools(
      messages, registry: @registry, session_id: @session.id,
      first_response: first_resp, between_rounds: between_rounds, **options
    )
    return unless result

    Events::Bus.emit(Events::AgentMessage.new(
      content: result[:text],
      session_id: @session.id,
      api_metrics: result[:api_metrics]
    ))
    result[:text]
  end

  # Clean up the underlying {ShellSession} PTY and resources.
  # Safe to call multiple times — subsequent calls are no-ops.
  def finalize
    @shell_session&.finalize
  end

  # Tool classes available to all sessions by default.
  # @return [Array<Class<Tools::Base>>]
  STANDARD_TOOLS = [Tools::Bash, Tools::Read, Tools::Write, Tools::Edit, Tools::WebGet, Tools::Think, Tools::Remember, Tools::Recall].freeze

  # Tools that bypass {Session#granted_tools} filtering.
  # The agent's reasoning depends on these regardless of task scope.
  # @return [Array<Class<Tools::Base>>]
  ALWAYS_GRANTED_TOOLS = [Tools::Think].freeze

  # Name-to-class mapping for tool restriction validation and registry building.
  # @return [Hash{String => Class<Tools::Base>}]
  STANDARD_TOOLS_BY_NAME = STANDARD_TOOLS.index_by(&:tool_name).freeze

  private

  # Assembles LLM options (system prompt, environment context).
  # Broadcasts the full debug context (system prompt + tool schemas)
  # to debug-mode TUI clients on every LLM request.
  # @return [Hash] options for {LLM::Client#chat_with_tools}
  def build_llm_options
    options = {}
    unless @session.sub_agent?
      env_context = EnvironmentProbe.to_prompt(@shell_session.pwd)
    end
    prompt = @session.system_prompt(environment_context: env_context)
    options[:system] = prompt if prompt
    @session.broadcast_debug_context(system: prompt, tools: @registry&.schemas)
    options
  end

  # Builds the tool registry appropriate for this session type.
  # Main sessions get standard tools + spawn_subagent + spawn_specialist.
  # Sub-agents get granted standard tools only (no spawning, no nesting).
  # Sub-agent results are delivered through natural text messages routed
  # by {Events::Subscribers::SubagentMessageRouter}.
  # When {Session#granted_tools} is nil, all standard tools are granted.
  # MCP tools from configured servers are registered for all session types.
  #
  # @return [Tools::Registry] registry with available tools
  def build_tool_registry
    context = {shell_session: @shell_session, session: @session}
    registry = Tools::Registry.new(context: context)

    granted_standard_tools.each { |tool| registry.register(tool) }

    if @session.sub_agent?
      registry.register(Tools::MarkGoalCompleted)
    else
      registry.register(Tools::SpawnSubagent)
      registry.register(Tools::SpawnSpecialist)
      registry.register(Tools::OpenIssue)
    end

    register_mcp_tools(registry)

    registry
  end

  # Loads tools from configured MCP servers and adds them to the registry.
  # Warnings are emitted as system messages — visible to both the user
  # (in verbose mode) and the LLM (via CONTEXT_TYPES) so the agent can
  # explain config issues instead of guessing.
  #
  # @param registry [Tools::Registry] the registry to add MCP tools to
  # @return [void]
  def register_mcp_tools(registry)
    warnings = Mcp::ClientManager.new.register_tools(registry)
    warnings.each do |message|
      Events::Bus.emit(Events::SystemMessage.new(content: message, session_id: @session.id))
    end
  end

  # Standard tools available to this session.
  # Returns all when {Session#granted_tools} is nil (no restriction).
  # Returns only matching tools when granted_tools is an array,
  # always including {ALWAYS_GRANTED_TOOLS}.
  #
  # @return [Array<Class<Tools::Base>>] tool classes to register
  def granted_standard_tools
    granted = @session.granted_tools
    return STANDARD_TOOLS unless granted

    explicitly_granted = granted.filter_map { |name| STANDARD_TOOLS_BY_NAME[name] }
    (ALWAYS_GRANTED_TOOLS + explicitly_granted).uniq
  end
end
