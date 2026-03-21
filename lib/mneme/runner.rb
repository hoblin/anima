# frozen_string_literal: true

module Mneme
  # Orchestrates the Mneme memory department — a phantom (non-persisted) LLM loop
  # that observes a main session's compressed viewport and creates summaries of
  # conversation context before it evicts from the viewport.
  #
  # Mneme is triggered when the terminal event (`mneme_boundary_event_id`) leaves
  # the viewport. It receives a compressed viewport (no raw tool calls, zone
  # delimiters present) and uses the `save_snapshot` tool to persist a summary.
  #
  # After completing, Mneme advances the terminal event to the boundary of what
  # it just summarized, so the cycle repeats as more events accumulate.
  #
  # @example
  #   Mneme::Runner.new(session).call
  class Runner
    TOOLS = [
      Tools::SaveSnapshot,
      Tools::EverythingOk
    ].freeze

    SYSTEM_PROMPT = <<~PROMPT
      You are Mneme, the memory department of an AI agent named Anima.
      Your job is to create concise summaries of conversation context that is
      about to leave the agent's context window.

      You MUST ONLY communicate through tool calls — NEVER output text.

      ──────────────────────────────
      WHAT YOU SEE
      ──────────────────────────────
      A compressed viewport with three zones:
      - EVICTION ZONE: Events about to leave the viewport. Summarize these.
      - MIDDLE ZONE: Events still visible but aging. Note key context.
      - RECENT ZONE: Fresh events. Use for continuity with the summary.

      Events are prefixed with `event N` (their database ID).
      Tool calls are compressed to `[N tools called]` — the mechanical work
      is not important, only the conversation flow.

      ──────────────────────────────
      YOUR TASK
      ──────────────────────────────
      1. Read the eviction zone carefully.
      2. If it contains meaningful conversation (decisions, goals, context):
         Call save_snapshot with a concise summary.
      3. If it contains only mechanical activity with no conversation:
         Call everything_ok.

      Write summaries that capture:
      - What was discussed and decided
      - Why decisions were made
      - Active goals and their progress
      - Key context the agent would need later

      Do NOT include:
      - Tool call details (which files were read, commands run)
      - Mechanical execution steps
      - Verbatim quotes (paraphrase instead)

      Always finish with exactly ONE tool call: either save_snapshot or everything_ok.
    PROMPT

    # @param session [Session] the main session to observe
    # @param client [LLM::Client, nil] injectable LLM client (defaults to fast model)
    def initialize(session, client: nil)
      @session = session
      @client = client || LLM::Client.new(
        model: Anima::Settings.fast_model,
        max_tokens: Anima::Settings.mneme_max_tokens,
        logger: Mneme.logger
      )
    end

    # Runs the Mneme loop: builds compressed viewport, calls LLM, executes
    # snapshot tool, then advances the terminal event pointer.
    #
    # @return [String, nil] the LLM's final text response (discarded),
    #   or nil if no context is available
    def call
      viewport = build_compressed_viewport
      compressed_text = viewport.render
      sid = @session.id

      if compressed_text.empty?
        log.debug("session=#{sid} — no events for Mneme, skipping")
        return
      end

      messages = build_messages(compressed_text)
      system = build_system_prompt

      log.info("session=#{sid} — running Mneme (#{viewport.events.size} events)")
      log.debug("compressed viewport:\n#{compressed_text}")

      result = @client.chat_with_tools(
        messages,
        registry: build_registry(viewport),
        session_id: nil,
        system: system
      )

      advance_boundary(viewport)
      log.info("session=#{sid} — Mneme done: #{result.to_s.truncate(200)}")
      result
    end

    private

    # Builds the compressed viewport starting from the session's boundary event.
    #
    # @return [Mneme::CompressedViewport]
    def build_compressed_viewport
      token_budget = (Anima::Settings.token_budget * Anima::Settings.mneme_viewport_fraction).to_i

      CompressedViewport.new(
        @session,
        token_budget: token_budget,
        from_event_id: @session.mneme_boundary_event_id
      )
    end

    # Frames the compressed viewport as a user message for the LLM.
    #
    # @param compressed_text [String] the rendered compressed viewport
    # @return [Array<Hash>] single-element messages array
    def build_messages(compressed_text)
      goals_context = active_goals_section

      content = <<~MSG.strip
        Here is the compressed viewport of the main session:

        #{compressed_text}
        #{goals_context}
        Review the eviction zone and decide whether to save a snapshot or signal everything_ok.
      MSG

      [{role: "user", content: content}]
    end

    # @return [String]
    def build_system_prompt
      SYSTEM_PROMPT
    end

    # Builds the tool registry with session context for SaveSnapshot.
    # Passes the event range from the viewport so the snapshot records
    # which events it covers.
    #
    # @param viewport [Mneme::CompressedViewport]
    # @return [Tools::Registry]
    def build_registry(viewport)
      viewport_events = viewport.events
      registry = ::Tools::Registry.new(context: {
        main_session: @session,
        from_event_id: viewport_events.first&.id,
        to_event_id: viewport_events.last&.id
      })
      TOOLS.each { |tool| registry.register(tool) }
      registry
    end

    # Advances the terminal event pointer after Mneme completes.
    # Sets it to the last conversation event in the viewport, ensuring
    # the boundary is always a message/think event, never a tool_call/tool_response.
    #
    # Also updates the snapshot range pointers.
    #
    # @param viewport [Mneme::CompressedViewport]
    def advance_boundary(viewport)
      viewport_events = viewport.events
      return if viewport_events.empty?

      new_boundary = viewport_events.reverse.find { |event| conversation_or_think?(event) }
      return unless new_boundary

      boundary_id = new_boundary.id
      updates = {mneme_boundary_event_id: boundary_id}

      updates[:mneme_snapshot_first_event_id] = viewport_events.first.id if @session.mneme_snapshot_first_event_id.nil?
      updates[:mneme_snapshot_last_event_id] = viewport_events.last.id

      @session.update_columns(updates)
      log.debug("session=#{@session.id} — boundary advanced to event #{boundary_id}")
    end

    # @return [Boolean] true if event is a conversation message or think tool_call
    def conversation_or_think?(event)
      event_type = event.event_type
      event_type.in?(%w[user_message agent_message system_message]) ||
        (event_type == "tool_call" && event.payload["tool_name"] == CompressedViewport::THINK_TOOL)
    end

    # Builds the active goals section for Mneme's context so it knows
    # what Goals exist and can reference them in summaries.
    #
    # @return [String] formatted goals section, or empty string
    def active_goals_section
      root_goals = @session.goals.root.includes(:sub_goals).active.order(:created_at)
      return "" if root_goals.empty?

      lines = root_goals.map { |goal| format_goal_for_mneme(goal) }
      "\n\n\u{1F3AF} Active Goals\n#{lines.join("\n")}\n"
    end

    # Formats a goal with sub-goals for Mneme's context.
    #
    # @param goal [Goal] root goal with preloaded sub_goals
    # @return [String]
    def format_goal_for_mneme(goal)
      parts = ["  \u25CF #{goal.description} (id: #{goal.id})"]
      goal.sub_goals.sort_by(&:created_at).each do |sub|
        checkbox = sub.completed? ? "[x]" : "[ ]"
        parts << "    #{checkbox} #{sub.description} (id: #{sub.id})"
      end
      parts.join("\n")
    end

    # @return [Logger]
    def log = Mneme.logger
  end
end
