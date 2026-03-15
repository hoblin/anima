# frozen_string_literal: true

module AnalyticalBrain
  # Orchestrates the analytical brain — a phantom (non-persisted) LLM loop
  # that observes a main session and performs background maintenance via tools.
  #
  # The analytical brain is a "subconscious" process: it operates ON the main
  # session without the main agent knowing it exists. Tools mutate the main
  # session directly (e.g. renaming it), but no trace of the analytical brain's
  # reasoning is persisted.
  #
  # Phase 1: session naming (rename_session + everything_is_ready).
  # Future phases add skill activation, goal tracking, and memory tools.
  #
  # @example
  #   AnalyticalBrain::Runner.new(session).call
  class Runner
    # How many recent events to include as context for the analytical brain.
    MAX_CONTEXT_EVENTS = 20

    # Tools available to the analytical brain.
    # @return [Array<Class<Tools::Base>>]
    TOOLS = [Tools::RenameSession, Tools::EverythingIsReady].freeze

    SYSTEM_PROMPT = <<~PROMPT
      You are the analytical brain — a subconscious process supporting the main agent.
      You observe the conversation and perform background maintenance.

      Your current responsibility: session naming.
      - Generate fun, descriptive session names: one emoji + 1-3 words
      - Rename when the conversation topic becomes clear or shifts significantly
      - Call everything_is_ready if the current name is already good

      Rules:
      - Always call exactly one tool: either rename_session or everything_is_ready
      - Never generate conversational text — you are a background process
    PROMPT

    # @param session [Session] the main session to observe and maintain
    # @param client [LLM::Client, nil] injectable LLM client (defaults to fast model)
    def initialize(session, client: nil)
      @session = session
      @client = client || LLM::Client.new(
        model: Anima::Settings.fast_model,
        max_tokens: 128
      )
    end

    # Runs the analytical brain loop. Builds context from the main session's
    # recent events, calls the LLM with the analytical brain's tool set, and
    # executes any tool calls against the main session.
    #
    # Events emitted during tool execution are not persisted — the phantom
    # session_id (nil) causes the global Persister to skip them.
    #
    # @return [String, nil] the LLM's final text response (discarded by caller),
    #   or nil if no context is available
    def call
      messages = build_messages
      return if messages.empty?

      @client.chat_with_tools(
        messages,
        registry: build_registry,
        session_id: nil,
        system: build_system_prompt
      )
    end

    private

    # Builds a condensed transcript of recent events as a single user message.
    # The analytical brain doesn't need multi-turn conversation history — it
    # just needs to understand "what is the agent doing RIGHT NOW?"
    #
    # @return [Array<Hash>] single-element messages array, or empty if no events
    def build_messages
      events = recent_events
      return [] if events.empty?

      transcript = events.filter_map { |event| format_event(event) }.join("\n")
      [{role: "user", content: transcript}]
    end

    # @return [Array<Event>] most recent events in chronological order
    def recent_events
      @session.events
        .context_events
        .reorder(id: :desc)
        .limit(MAX_CONTEXT_EVENTS)
        .to_a
        .reverse
    end

    # Formats a single event for the analytical brain's transcript.
    #
    # @param event [Event]
    # @return [String, nil] formatted line, or nil for unknown event types
    def format_event(event)
      payload = event.payload
      summary = payload["content"].to_s.truncate(500)

      case event.event_type
      when "user_message" then "User: #{summary}"
      when "agent_message" then "Assistant: #{summary}"
      when "tool_call" then "Tool call: #{payload["tool_name"]}"
      when "tool_response" then "Tool result: #{summary.truncate(200)}"
      end
    end

    # Builds the system prompt with current session state so the analytical
    # brain can decide whether renaming is needed.
    #
    # @return [String]
    def build_system_prompt
      "#{SYSTEM_PROMPT}\nCurrent session name: #{@session.name || "(unnamed)"}"
    end

    # @return [Tools::Registry] registry with analytical brain tools
    def build_registry
      registry = ::Tools::Registry.new(context: {main_session: @session})
      TOOLS.each { |tool| registry.register(tool) }
      registry
    end
  end
end
