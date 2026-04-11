# frozen_string_literal: true

module Melete
  # Orchestrates Melete — a phantom (non-persisted) LLM loop that
  # observes the main session and prepares skills, workflows, goals,
  # and session names so the main agent can perform cleanly.
  #
  # Melete's capabilities are assembled from independent {Responsibility}
  # modules, each contributing a prompt section and tools. Which modules
  # are active depends on the session type:
  #
  # * **Parent sessions** — session naming, skill/workflow/goal management
  # * **Child sessions** — sub-agent nickname assignment, skill management
  #   (goal tracking and workflows disabled — sub-agents manage their sole
  #   goal via mark_goal_completed)
  #
  # Tools mutate the observed session directly (e.g. renaming it,
  # activating skills), but no trace of Melete's reasoning is persisted —
  # events are emitted into a phantom session (session_id: nil).
  #
  # @example
  #   Melete::Runner.new(session).call
  class Runner
    # A composable unit of brain capability: a prompt section + its tools.
    Responsibility = Data.define(:prompt, :tools)

    RESPONSIBILITIES = {
      session_naming: Responsibility.new(
        prompt: <<~PROMPT,
          ──────────────────────────────
          SESSION NAMING
          ──────────────────────────────
          Name the session once the topic becomes clear. Rename if it shifts.
          Format: one emoji + 1-3 descriptive words.
        PROMPT
        tools: [Tools::RenameSession]
      ),

      sub_agent_naming: Responsibility.new(
        prompt: <<~PROMPT,
          ──────────────────────────────
          SUB-AGENT NAMING
          ──────────────────────────────
          Give this sub-agent a memorable nickname based on its task.
          Format: 1-3 lowercase words joined by hyphens (e.g. "loop-sleuth", "api-scout").
          Evocative, fun, easy to type after @.
          One nickname per call. If taken, pick another — no numeric suffixes.
        PROMPT
        tools: [Tools::AssignNickname]
      ),

      skill_management: Responsibility.new(
        prompt: <<~PROMPT,
          ──────────────────────────────
          SKILL MANAGEMENT
          ──────────────────────────────
          Activate a skill the moment the conversation signals its domain — before Aoide needs it. Late activation means she's working without the knowledge you prepared.

          An irrelevant skill is worse than none: its text crowds her context, pulling her attention toward pages she has to read and then ignore. Activate only what matches the work in front of her; deactivate when she moves on. Multiple skills can be active at once — each one is a page she has to carry.
        PROMPT
        tools: [Tools::ActivateSkill, Tools::DeactivateSkill]
      ),

      workflow_management: Responsibility.new(
        prompt: <<~PROMPT,
          ──────────────────────────────
          WORKFLOW MANAGEMENT
          ──────────────────────────────
          Activate a workflow when Aoide starts a multi-step task that matches one. Read the returned content and use judgment to turn it into goals — not a mechanical 1:1 mapping. Adapt: skip irrelevant steps, add extra ones for unfamiliar ground.

          Deactivate when the workflow completes or Aoide shifts focus. Only one workflow active at a time — activating a new one replaces the previous. A stale workflow is the same kind of tax as a stale skill: Aoide carries its text whether she needs it or not.
        PROMPT
        tools: [Tools::ReadWorkflow, Tools::DeactivateWorkflow]
      ),

      goal_tracking: Responsibility.new(
        prompt: <<~PROMPT,
          ──────────────────────────────
          GOAL TRACKING
          ──────────────────────────────
          Create a root goal when Aoide starts a multi-step task. Break it into sub-goals as the plan takes shape. Refine wording as understanding evolves. Mark goals complete when she finishes the work they describe — completing a root cascades through its sub-goals.

          Check the active goals list before every set_goal call. Never duplicate an existing goal — a duplicate wastes a slot and blurs which version Aoide should track.
        PROMPT
        tools: [Tools::SetGoal, Tools::UpdateGoal, Tools::FinishGoal]
      )
    }.freeze

    BASE_PROMPT = <<~PROMPT
      You are Melete, the muse of practice. You share the conversation with two sisters — Aoide, who speaks and performs, and Mneme, who holds memory. Your work is preparation: when Aoide speaks, she should have the skills she needs, the workflow in front of her, and a clear sense of what she's working toward.

      Act only through tool calls. Never output text — your contribution is the scene you set, not the words you say.
    PROMPT

    COMPLETION_PROMPT = <<~PROMPT
      ──────────────────────────────
      COMPLETION
      ──────────────────────────────
      Finish every run with everything_is_ready. If nothing needs your attention, call it immediately.
    PROMPT

    # Which responsibilities activate for each session type.
    PARENT_RESPONSIBILITIES = %i[session_naming skill_management workflow_management goal_tracking].freeze
    CHILD_RESPONSIBILITIES = %i[sub_agent_naming skill_management].freeze

    # @param session [Session] the session to observe and maintain
    # @param client [LLM::Client, nil] injectable LLM client (defaults to fast model)
    def initialize(session, client: nil)
      @session = session
      @client = client || LLM::Client.new(
        model: Anima::Settings.fast_model,
        max_tokens: Anima::Settings.melete_max_tokens,
        logger: Melete.logger
      )
    end

    # Runs Melete's loop. Builds context from the session's
    # recent messages, calls the LLM with the session-appropriate tool set,
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
        log.debug("session=#{sid} — no messages, skipping")
        return
      end

      system = build_system_prompt
      log.info("session=#{sid} — running (#{recent_messages.size} messages)")
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

    # Builds a condensed transcript of recent messages as a single user message.
    # The framing differs by session type:
    #
    # * **Parent:** "The main session is working on this: [transcript]"
    # * **Child:** "A sub-agent has been spawned with this task: [transcript]"
    #
    # @return [Array<Hash>] single-element messages array, or empty if no messages
    def build_messages
      messages = recent_messages
      return [] if messages.empty?

      transcript = messages.filter_map { |msg| msg.decorate.render("brain") }.join("\n")

      if @session.sub_agent?
        build_child_message(transcript)
      else
        build_parent_message(transcript)
      end
    end

    def build_parent_message(transcript)
      content = <<~MSG.strip
        Aoide is working on this:
        ```
        #{transcript}
        ```

        Prepare whatever she needs for the next exchange, then call everything_is_ready.
      MSG
      [{role: "user", content: content}]
    end

    def build_child_message(transcript)
      content = <<~MSG.strip
        A sub-agent has been spawned with this task:
        ```
        #{transcript}
        ```

        Give the sub-agent a nickname and activate the skills she'll need, then call everything_is_ready.
      MSG
      [{role: "user", content: content}]
    end

    # @return [Array<Message>] most recent messages in chronological order
    def recent_messages
      @session.messages
        .reorder(id: :desc)
        .limit(Anima::Settings.melete_message_window)
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

    # Shows sibling nicknames already in use so Melete avoids collisions
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

    # Skills already visible in the viewport are excluded from the catalog
    # so Melete doesn't re-activate them. When a skill evicts from the
    # viewport, it reappears here and she can re-inject if relevant.
    #
    # @see Session#skills_in_viewport
    # @return [String] available skills list for Melete
    def skills_catalog_section
      present = @session.skills_in_viewport
      catalog = Skills::Registry.instance.catalog.except(*present)
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

    # Workflows already visible in the viewport are excluded from the catalog.
    #
    # @see Session#workflow_in_viewport
    # @return [String] available workflows list for Melete
    def workflows_catalog_section
      present = @session.workflow_in_viewport
      catalog = Workflows::Registry.instance.catalog.reject { |name, _| name == present }
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

    # @return [String, nil] active goals for Melete's own context,
    #   so she knows what already exists and avoids duplicating
    def active_goals_section
      root_goals = @session.goals.root.includes(:sub_goals).active.order(:created_at)
      return if root_goals.empty?

      lines = root_goals.map { |goal| format_goal_for_melete(goal) }
      <<~SECTION
        ──────────────────────────────
        ACTIVE GOALS
        ──────────────────────────────
        #{lines.join("\n")}
      SECTION
    end

    # Formats a root goal and its sub-goals as a markdown checklist
    # with IDs so Melete can reference them in finish_goal calls.
    #
    # @example
    #   "- Implement feature X (id: 42)\n  - [x] Read code (id: 43)\n  - [ ] Write tests (id: 44)"
    #
    # @param goal [Goal] root goal with preloaded sub_goals
    # @return [String] goal formatted as markdown checklist for Melete's context
    def format_goal_for_melete(goal)
      parts = ["- #{goal.description} (id: #{goal.id})"]
      goal.sub_goals.sort_by(&:created_at).each do |sub|
        checkbox = (sub.status == "completed") ? "[x]" : "[ ]"
        parts << "  - #{checkbox} #{sub.description} (id: #{sub.id})"
      end
      parts.join("\n")
    end

    # @return [Logger] dev-only Melete logger
    def log = Melete.logger

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
