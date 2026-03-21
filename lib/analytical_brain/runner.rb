# frozen_string_literal: true

module AnalyticalBrain
  # Orchestrates the analytical brain — a phantom (non-persisted) LLM loop
  # that observes a session and performs background maintenance via tools.
  #
  # The brain's capabilities are assembled from independent {Responsibility}
  # modules, each contributing a prompt section and tools. Which modules are
  # active depends on the session type:
  #
  # * **Parent sessions** — session naming, skill/workflow/goal management
  # * **Child sessions** — sub-agent nickname assignment, skill/workflow/goal management
  #
  # Tools mutate the observed session directly (e.g. renaming it, activating
  # skills), but no trace of the brain's reasoning is persisted — events are
  # emitted into a phantom session (session_id: nil).
  #
  # @example
  #   AnalyticalBrain::Runner.new(session).call
  class Runner
    # A composable unit of brain capability: a prompt section + its tools.
    Responsibility = Data.define(:prompt, :tools)

    RESPONSIBILITIES = {
      session_naming: Responsibility.new(
        prompt: <<~PROMPT,
          ──────────────────────────────
          SESSION NAMING
          ──────────────────────────────
          Call rename_session when the topic becomes clear or shifts.
          Format: one emoji + 1-3 descriptive words.
        PROMPT
        tools: [Tools::RenameSession]
      ),

      sub_agent_naming: Responsibility.new(
        prompt: <<~PROMPT,
          ──────────────────────────────
          SUB-AGENT NAMING
          ──────────────────────────────
          Call assign_nickname to give this sub-agent a short, memorable nickname.
          Format: 1-3 lowercase words joined by hyphens (e.g. "loop-sleuth", "api-scout").
          Evocative of the task, fun, easy to type after @.
          Generate EXACTLY ONE nickname. If taken, pick another — no numeric suffixes.
        PROMPT
        tools: [Tools::AssignNickname]
      ),

      skill_management: Responsibility.new(
        prompt: <<~PROMPT,
          ──────────────────────────────
          SKILL MANAGEMENT
          ──────────────────────────────
          Call activate_skill when the conversation matches a skill's description.
          Call deactivate_skill when the agent moves to a different domain.
          Multiple skills can be active at once.
        PROMPT
        tools: [Tools::ActivateSkill, Tools::DeactivateSkill]
      ),

      workflow_management: Responsibility.new(
        prompt: <<~PROMPT,
          ──────────────────────────────
          WORKFLOW MANAGEMENT
          ──────────────────────────────
          Call read_workflow when the user starts a multi-step task matching a workflow description.
          Read the returned content and use judgment to create appropriate goals — not a mechanical 1:1 mapping.
          Adapt to context: skip irrelevant steps, add extra steps for unfamiliar areas.
          Call deactivate_workflow when the workflow completes or the user shifts focus.
          Only one workflow can be active at a time — activating a new one replaces the previous.
        PROMPT
        tools: [Tools::ReadWorkflow, Tools::DeactivateWorkflow]
      ),

      goal_tracking: Responsibility.new(
        prompt: <<~PROMPT,
          ──────────────────────────────
          GOAL TRACKING
          ──────────────────────────────
          Call set_goal to create a root goal when the user starts a multi-step task.
          Call set_goal with parent_goal_id to add sub-goals (TODO items) under it.
          Call update_goal to refine a goal's description as understanding evolves.
          Call finish_goal when the main agent completes work a goal describes.
          Finishing a root goal cascades — all active sub-goals are completed too.
          Never duplicate an existing goal — check the active goals list first.
        PROMPT
        tools: [Tools::SetGoal, Tools::UpdateGoal, Tools::FinishGoal]
      )
    }.freeze

    BASE_PROMPT = <<~PROMPT
      You are a background automation that manages session metadata.
      You MUST ONLY communicate through tool calls — NEVER output text.
      Always finish by calling everything_is_ready.
    PROMPT

    COMPLETION_PROMPT = <<~PROMPT
      ──────────────────────────────
      COMPLETION
      ──────────────────────────────
      Call everything_is_ready as your LAST tool call, every time.
      If nothing needs changing, call it immediately as your only tool call.
    PROMPT

    # Which responsibilities activate for each session type.
    PARENT_RESPONSIBILITIES = %i[session_naming skill_management workflow_management goal_tracking].freeze
    CHILD_RESPONSIBILITIES = %i[sub_agent_naming skill_management workflow_management goal_tracking].freeze

    # @param session [Session] the session to observe and maintain
    # @param client [LLM::Client, nil] injectable LLM client (defaults to fast model)
    def initialize(session, client: nil)
      @session = session
      @client = client || LLM::Client.new(
        model: Anima::Settings.fast_model,
        max_tokens: Anima::Settings.analytical_brain_max_tokens,
        logger: AnalyticalBrain.logger
      )
    end

    # Runs the analytical brain loop. Builds context from the session's
    # recent events, calls the LLM with the session-appropriate tool set,
    # and executes any tool calls against the session.
    #
    # Events emitted during tool execution are not persisted — the phantom
    # session_id (nil) causes the global Persister to skip them.
    #
    # @return [String, nil] the LLM's final text response (discarded by caller),
    #   or nil if no context is available
    def call
      messages = build_messages
      sid = @session.id
      if messages.empty?
        log.debug("session=#{sid} — no events, skipping")
        return
      end

      system = build_system_prompt
      log.info("session=#{sid} — running (#{recent_events.size} events)")
      log.debug("system prompt:\n#{system}")
      log.debug("user message:\n#{messages.first[:content]}")

      result = @client.chat_with_tools(
        messages,
        registry: build_registry,
        session_id: nil,
        system: system
      )

      log.info("session=#{sid} — done: #{result.to_s.truncate(200)}")
      result
    end

    private

    # @return [Array<Symbol>] responsibility keys for this session type
    def active_responsibility_keys
      @session.sub_agent? ? CHILD_RESPONSIBILITIES : PARENT_RESPONSIBILITIES
    end

    # @return [Array<Responsibility>] active responsibility modules
    def active_responsibilities
      active_responsibility_keys.map { |key| RESPONSIBILITIES.fetch(key) }
    end

    # Builds a condensed transcript of recent events as a single user message.
    # The framing differs by session type:
    #
    # * **Parent:** "The main session is working on this: [transcript]"
    # * **Child:** "A sub-agent has been spawned with this task: [transcript]"
    #
    # @return [Array<Hash>] single-element messages array, or empty if no events
    def build_messages
      events = recent_events
      return [] if events.empty?

      transcript = events.filter_map { |event| EventDecorator.for(event)&.render("brain") }.join("\n")

      if @session.sub_agent?
        build_child_message(transcript)
      else
        build_parent_message(transcript)
      end
    end

    def build_parent_message(transcript)
      content = <<~MSG.strip
        The main session is working on this:
        ```
        #{transcript}
        ```

        Observe the conversation and take action: manage goals, activate or deactivate relevant skills, read workflows when a multi-step task matches, rename the session if needed, then call everything_is_ready.
      MSG
      [{role: "user", content: content}]
    end

    def build_child_message(transcript)
      content = <<~MSG.strip
        A sub-agent has been spawned with this task:
        ```
        #{transcript}
        ```

        Assign a memorable nickname based on the task, activate relevant skills, then call everything_is_ready.
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

    # Builds the system prompt from active responsibilities + context sections.
    #
    # @return [String]
    def build_system_prompt
      sections = [
        BASE_PROMPT,
        *active_responsibilities.map(&:prompt),
        COMPLETION_PROMPT,
        session_state_section,
        active_siblings_section,
        skills_catalog_section,
        workflows_catalog_section,
        active_goals_section
      ]
      sections.compact.join("\n")
    end

    # @return [String] current session name, active skills, and active workflow
    def session_state_section
      name = @session.name || "(unnamed)"
      skills = @session.active_skills.join(", ").presence || "None"
      workflow = @session.active_workflow || "None"
      <<~SECTION
        ──────────────────────────────
        CURRENT STATE
        ──────────────────────────────
        Session name: #{name}
        Active skills: #{skills}
        Active workflow: #{workflow}
      SECTION
    end

    # Shows sibling nicknames already in use so the brain avoids collisions
    # at prompt level (the tool also validates at execution time).
    #
    # @return [String, nil] sibling names section, or nil for parent sessions
    def active_siblings_section
      return unless @session.sub_agent?

      siblings = @session.parent_session.child_sessions
        .where.not(id: @session.id)
        .where.not(name: nil)
        .pluck(:name)
      return if siblings.empty?

      <<~SECTION
        ──────────────────────────────
        ACTIVE SIBLINGS
        ──────────────────────────────
        These nicknames are already taken: #{siblings.join(", ")}
      SECTION
    end

    # @return [String] available skills list for the analytical brain
    def skills_catalog_section
      catalog = Skills::Registry.instance.catalog
      items = if catalog.empty?
        "None"
      else
        catalog.map { |name, desc| "- #{name} — #{desc}" }.join("\n")
      end
      <<~SECTION
        ──────────────────────────────
        AVAILABLE SKILLS
        ──────────────────────────────
        #{items}
      SECTION
    end

    # @return [String] available workflows list for the analytical brain
    def workflows_catalog_section
      catalog = Workflows::Registry.instance.catalog
      items = if catalog.empty?
        "None"
      else
        catalog.map { |name, desc| "- #{name} — #{desc}" }.join("\n")
      end
      <<~SECTION
        ──────────────────────────────
        AVAILABLE WORKFLOWS
        ──────────────────────────────
        #{items}
      SECTION
    end

    # @return [String, nil] active goals for the brain's own context,
    #   so it knows what already exists and avoids duplicating
    def active_goals_section
      root_goals = @session.goals.root.includes(:sub_goals).active.order(:created_at)
      return if root_goals.empty?

      lines = root_goals.map { |goal| format_goal_for_brain(goal) }
      <<~SECTION
        ──────────────────────────────
        ACTIVE GOALS
        ──────────────────────────────
        #{lines.join("\n")}
      SECTION
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

    # @return [Logger] dev-only analytical brain logger
    def log = AnalyticalBrain.logger

    # @return [Tools::Registry] registry with tools from active responsibilities
    def build_registry
      registry = ::Tools::Registry.new(context: {main_session: @session})
      active_tools.each { |tool| registry.register(tool) }
      registry
    end

    # @return [Array<Class<Tools::Base>>] tools from all active responsibilities + completion
    def active_tools
      active_responsibilities.flat_map(&:tools) + [Tools::EverythingIsReady]
    end
  end
end
