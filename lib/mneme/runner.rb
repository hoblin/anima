# frozen_string_literal: true

module Mneme
  # Orchestrates the Mneme memory department — a phantom (non-persisted) LLM loop
  # that observes a main session's compressed viewport and creates summaries of
  # conversation context before it evicts from the viewport.
  #
  # Mneme is triggered when the terminal message (`mneme_boundary_message_id`) leaves
  # the viewport. It receives a compressed viewport (no raw tool calls, zone
  # delimiters present) and uses the `save_snapshot` tool to persist a summary.
  #
  # After completing, Mneme advances the terminal message to the boundary of what
  # it just summarized, so the cycle repeats as more messages accumulate.
  #
  # @example
  #   Mneme::Runner.new(session).call
  class Runner
    TOOLS = [
      Tools::SaveSnapshot,
      Tools::AttachMessagesToGoals,
      Tools::EverythingOk
    ].freeze

    SYSTEM_PROMPT = <<~PROMPT
      You are Mneme, the memory department of an AI agent named Anima.
      The agent's context is a conveyor belt — events flow through and eventually fall off.
      Remember what matters. Let the rest go.
      Communicate only through tool calls — never output text.

      ──────────────────────────────
      VIEWPORT
      ──────────────────────────────
      Three zones, oldest to newest:
      - EVICTION ZONE: About to fall off — read carefully, this is your focus.
      - MIDDLE ZONE: Aging but visible. Note context that connects to evicting events.
      - RECENT ZONE: Fresh. Use for continuity with your summary.

      Messages are prefixed with `message N` (database ID, used for pinning).
      Tool calls are compressed to `[N tools called]` — focus on conversation, not mechanical work.

      ──────────────────────────────
      ACTIONS
      ──────────────────────────────
      Summarize evicting conversation with save_snapshot — capture what was discussed and decided,
      why decisions were made, active goal progress, and context the agent will need later.
      Paraphrase — don't quote verbatim. Omit tool call details and mechanical steps.

      Pin critical messages to goals with attach_messages_to_goals when exact wording matters
      (user instructions, key corrections, key decisions). Pinned messages survive eviction
      intact — use this sparingly for messages where paraphrasing would lose meaning.

      If the eviction zone contains only mechanical activity, call everything_ok.

      You may combine save_snapshot and attach_messages_to_goals in one turn.
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
    # snapshot tool, then advances the terminal message pointer.
    #
    # @return [String, nil] the LLM's final text response (discarded),
    #   or nil if no context is available
    def call
      viewport = build_compressed_viewport
      compressed_text = viewport.render
      sid = @session.id

      if compressed_text.empty?
        log.debug("session=#{sid} — no messages for Mneme, skipping")
        return
      end

      llm_messages = build_messages(compressed_text)
      system = SYSTEM_PROMPT

      log.info("session=#{sid} — running Mneme (#{viewport.messages.size} messages)")
      log.debug("compressed viewport:\n#{compressed_text}")

      result = @client.chat_with_tools(
        llm_messages,
        registry: build_registry(viewport),
        session_id: nil,
        system: system
      )

      advance_boundary(viewport)
      log.info("session=#{sid} — Mneme done: #{result.to_s.truncate(200)}")
      result
    end

    private

    # Builds the compressed viewport starting from the session's boundary message.
    #
    # @return [Mneme::CompressedViewport]
    def build_compressed_viewport
      token_budget = (Anima::Settings.token_budget * Anima::Settings.mneme_viewport_fraction).to_i

      CompressedViewport.new(
        @session,
        token_budget: token_budget,
        from_message_id: @session.mneme_boundary_message_id
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

    # Builds the tool registry with session context for SaveSnapshot.
    # Passes the message range from the viewport so the snapshot records
    # which messages it covers.
    #
    # @param viewport [Mneme::CompressedViewport]
    # @return [Tools::Registry]
    def build_registry(viewport)
      viewport_messages = viewport.messages
      registry = ::Tools::Registry.new(context: {
        main_session: @session,
        from_message_id: viewport_messages.first&.id,
        to_message_id: viewport_messages.last&.id
      })
      TOOLS.each { |tool| registry.register(tool) }
      registry
    end

    # Advances the terminal message pointer past the zone Mneme just processed.
    # Runs unconditionally — even when the LLM called `everything_ok` (no snapshot
    # needed), the zone was reviewed and should be advanced past. Without this,
    # Mneme would re-examine the same mechanical-only content on every trigger.
    #
    # Sets the boundary to the first conversation/think message AFTER Mneme's
    # viewport — the start of the remaining context. This creates the batch
    # eviction cycle: the next Mneme trigger fires only after this boundary
    # message itself falls out of the main viewport (~1/3 turnover later).
    # Also updates the snapshot range pointers.
    #
    # @param viewport [Mneme::CompressedViewport]
    def advance_boundary(viewport)
      viewport_messages = viewport.messages
      return if viewport_messages.empty?

      last_processed_id = viewport_messages.last.id
      new_boundary = @session.messages
        .where("id > ?", last_processed_id)
        .order(:id)
        .find { |msg| conversation_or_think?(msg) }

      # Fall back to the last message in Mneme's viewport when no conversation
      # messages exist beyond it (e.g. session went quiet after the zone).
      new_boundary ||= viewport_messages.reverse_each.find { |msg| conversation_or_think?(msg) }
      return unless new_boundary

      boundary_id = new_boundary.id
      updates = {mneme_boundary_message_id: boundary_id}

      updates[:mneme_snapshot_first_message_id] = viewport_messages.first.id unless @session.mneme_snapshot_first_message_id
      updates[:mneme_snapshot_last_message_id] = viewport_messages.last.id

      @session.update_columns(updates)
      log.debug("session=#{@session.id} — boundary advanced to message #{boundary_id}")
    end

    # Delegates to {Message#conversation_or_think?} — single source of truth
    # for which messages Mneme treats as conversation boundaries.
    #
    # @return [Boolean]
    def conversation_or_think?(message)
      message.conversation_or_think?
    end

    # Builds the active goals section for Mneme's context so it knows
    # what Goals exist, which messages are already pinned, and can reference
    # them when deciding what to pin or summarize.
    #
    # @return [String] formatted goals section, or empty string
    def active_goals_section
      root_goals = @session.goals.root.includes(:sub_goals).active.order(:created_at)
      return "" if root_goals.empty?

      lines = root_goals.map { |goal| format_goal_for_mneme(goal) }
      pinned = format_existing_pins

      section = "\n\n🎯 Active Goals\n#{lines.join("\n")}\n"
      section += "\n📌 Already Pinned\n#{pinned}\n" if pinned
      section
    end

    # Formats a goal with sub-goals for Mneme's context.
    #
    # @param goal [Goal] root goal with preloaded sub_goals
    # @return [String]
    def format_goal_for_mneme(goal)
      parts = ["  ● #{goal.description} (id: #{goal.id})"]
      goal.sub_goals.each do |sub|
        checkbox = sub.completed? ? "[x]" : "[ ]"
        parts << "    #{checkbox} #{sub.description} (id: #{sub.id})"
      end
      parts.join("\n")
    end

    # Lists already-pinned message IDs so Mneme avoids redundant pinning.
    #
    # @return [String, nil] formatted pin list, or nil when nothing is pinned
    def format_existing_pins
      pins = @session.pinned_messages.includes(:goals).order(:message_id)
      return nil if pins.empty?

      pins.map { |pin| format_pin_for_mneme(pin) }.join("\n")
    end

    # @param pin [PinnedMessage] pin with preloaded goals
    # @return [String] formatted pin line
    def format_pin_for_mneme(pin)
      goal_ids = pin.goals.map(&:id).join(", ")
      "  message #{pin.message_id} → goals [#{goal_ids}]"
    end

    # @return [Logger]
    def log = Mneme.logger
  end
end
