# frozen_string_literal: true

module AnalyticalBrain
  # Orchestrates the analytical brain — a phantom (non-persisted) LLM loop
  # that observes a main session and performs background maintenance via tools.
  #
  # The analytical brain is a "subconscious" process: it operates ON the main
  # session without the main agent knowing it exists. Tools mutate the main
  # session directly (e.g. renaming it, activating skills), but no trace of
  # the analytical brain's reasoning is persisted.
  #
  # @example
  #   AnalyticalBrain::Runner.new(session).call
  class Runner
    # Tools available to the analytical brain.
    # @return [Array<Class<Tools::Base>>]
    TOOLS = [
      Tools::RenameSession,
      Tools::ActivateSkill,
      Tools::DeactivateSkill,
      Tools::SetGoal,
      Tools::FinishGoal,
      Tools::EverythingIsReady
    ].freeze

    SYSTEM_PROMPT = <<~PROMPT
      You are the analytical brain — a subconscious process supporting the main agent.
      You observe the conversation and manage background tasks.

      ## Responsibilities

      ### Session naming
      - Generate fun, descriptive names: one emoji + 1-3 words
      - Rename when the topic becomes clear or shifts significantly

      ### Knowledge activation
      - Activate skills when conversation context matches a skill's description
      - Deactivate skills when the agent has moved to a different domain
      - Multiple skills can be active simultaneously

      ### Goal tracking
      - Set goals when the user expresses multi-step intentions or starts a new task
      - Break complex goals into sub-goals (short-term TODO items under a root goal)
      - Mark goals as completed when the main agent finishes the work they describe
      - Do not duplicate goals that already exist — check the active goals list first

      ## Rules
      - Call tools to make changes, then call everything_is_ready when done
      - Call everything_is_ready immediately if no changes are needed
      - Never generate conversational text — you are a background process
    PROMPT

    # @param session [Session] the main session to observe and maintain
    # @param client [LLM::Client, nil] injectable LLM client (defaults to fast model)
    def initialize(session, client: nil)
      @session = session
      @client = client || LLM::Client.new(
        model: Anima::Settings.fast_model,
        max_tokens: Anima::Settings.analytical_brain_max_tokens
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
    # The transcript is framed as an observation of the main session, not as
    # a direct message to the analytical brain. Without this framing, Haiku
    # confuses the main session's user messages with requests directed at it.
    #
    # @return [Array<Hash>] single-element messages array, or empty if no events
    def build_messages
      events = recent_events
      return [] if events.empty?

      transcript = events.filter_map { |event| format_event(event) }.join("\n")
      content = <<~MSG.strip
        The main session is working on this:
        ```
        #{transcript}
        ```

        Observe the conversation and take action: manage goals, activate or deactivate relevant skills, rename the session if needed, then call everything_is_ready.
      MSG
      [{role: "user", content: content}]
    end

    # @return [Array<Event>] most recent events in chronological order
    def recent_events
      @session.events
        .context_events
        .reorder(id: :desc)
        .limit(Anima::Settings.analytical_brain_event_window)
        .to_a
        .reverse
    end

    # Formats a single event for the analytical brain's transcript.
    # User/agent messages get 500 chars to preserve conversation context;
    # tool responses get 200 chars to reduce noise from verbose outputs.
    #
    # @param event [Event]
    # @return [String, nil] formatted line, or nil for unhandled event types
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

    # Builds the system prompt with current session state, skills catalog,
    # and currently active skills.
    #
    # @return [String]
    def build_system_prompt
      [
        SYSTEM_PROMPT,
        skills_catalog_section,
        active_skills_section,
        active_goals_section,
        "Current session name: #{@session.name || "(unnamed)"}"
      ].compact.join("\n")
    end

    # @return [String] available skills list for the analytical brain
    def skills_catalog_section
      catalog = Skills::Registry.instance.catalog
      return "## Available skills\nNone" if catalog.empty?

      lines = catalog.map { |name, desc| "- #{name} — #{desc}" }
      "## Available skills\n#{lines.join("\n")}"
    end

    # @return [String] currently active skills list
    def active_skills_section
      list = @session.active_skills.join(", ").presence || "None"
      "## Currently active skills\n#{list}"
    end

    # @return [String, nil] active goals for the brain's own context,
    #   so it knows what already exists and avoids duplicating
    def active_goals_section
      root_goals = @session.goals.root.includes(:sub_goals).active.order(:created_at)
      return if root_goals.empty?

      lines = root_goals.map { |goal| format_goal_for_brain(goal) }
      "## Active goals\n#{lines.join("\n")}"
    end

    # Formats a root goal and its sub-goals as a markdown checklist
    # with IDs so the brain can reference them in finish_goal calls.
    #
    # @example
    #   "- Implement feature X (id: 42)\n  - [x] Read code (id: 43)\n  - [ ] Write tests (id: 44)"
    #
    # @param goal [Goal] root goal with preloaded sub_goals
    # @return [String] goal formatted as markdown checklist for brain context
    def format_goal_for_brain(goal)
      parts = ["- #{goal.description} (id: #{goal.id})"]
      goal.sub_goals.sort_by(&:created_at).each do |sub|
        checkbox = (sub.status == "completed") ? "[x]" : "[ ]"
        parts << "  - #{checkbox} #{sub.description} (id: #{sub.id})"
      end
      parts.join("\n")
    end

    # @return [Tools::Registry] registry with analytical brain tools
    def build_registry
      registry = ::Tools::Registry.new(context: {main_session: @session})
      TOOLS.each { |tool| registry.register(tool) }
      registry
    end
  end
end
