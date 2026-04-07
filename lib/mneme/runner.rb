# frozen_string_literal: true

module Mneme
  # Orchestrates the Mneme memory department — a phantom (non-persisted) LLM loop
  # that summarizes the eviction zone before those messages drift out of the
  # viewport.
  #
  # The eviction zone is the oldest slice of the conversation starting from the
  # boundary, sized by {Anima::Settings.eviction_fraction}. The LLM sees the
  # eviction zone (what to summarize) plus the remaining viewport (context).
  #
  # After completing, Mneme advances the boundary past the eviction zone so the
  # cycle repeats as more messages accumulate.
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
      Two sections, oldest to newest:
      - EVICTION ZONE: About to fall off — read carefully, this is your focus.
      - CONTEXT: The live viewport past the eviction zone. Use for continuity with your summary.

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

    # Runs the Mneme loop: builds eviction zone + context, calls LLM,
    # executes snapshot tool, then advances the boundary.
    #
    # @return [String, nil] the LLM's final text response (discarded),
    #   or nil if no context is available
    def call
      eviction = @session.eviction_zone_messages.to_a
      sid = @session.id

      if eviction.empty?
        log.debug("session=#{sid} — no messages for Mneme, skipping")
        return
      end

      context = @session.viewport_messages.where("messages.id > ?", eviction.last.id).to_a
      compressed_text = render_transcript(eviction, context)

      llm_messages = build_messages(compressed_text)

      log.info("session=#{sid} — running Mneme (#{eviction.size} eviction + #{context.size} context)")
      log.debug("compressed viewport:\n#{compressed_text}")

      result = @client.chat_with_tools(
        llm_messages,
        registry: build_registry(eviction),
        session_id: nil,
        system: SYSTEM_PROMPT
      )

      advance_boundary(eviction)
      log.info("session=#{sid} — Mneme done: #{result.to_s.truncate(200)}")
      result
    end

    private

    # Renders eviction zone and context as a Mneme transcript using
    # message decorators. Tool calls are compressed into counters.
    #
    # @param eviction [Array<Message>] messages in the eviction zone
    # @param context [Array<Message>] remaining viewport messages
    # @return [String] formatted transcript with zone delimiters
    def render_transcript(eviction, context)
      sections = []
      sections << "── EVICTION ZONE ──"
      sections << render_messages(eviction)
      sections << "── CONTEXT ──"
      sections << render_messages(context)
      sections.join("\n")
    end

    # Renders a list of messages using decorators, compressing consecutive
    # tool calls into `[N tools called]` counters.
    #
    # @param messages [Array<Message>] messages to render
    # @return [String] rendered transcript lines
    def render_messages(messages)
      lines = []
      tool_count = 0

      messages.each do |message|
        rendered = MessageDecorator.for(message)&.render("mneme")

        if rendered == :tool_call
          tool_count += 1
        else
          lines << flush_tool_count(tool_count) if tool_count > 0
          tool_count = 0
          lines << rendered if rendered
        end
      end

      lines << flush_tool_count(tool_count) if tool_count > 0
      lines.compact.join("\n")
    end

    # @return [String] tool count summary line
    def flush_tool_count(count)
      "[#{count} #{(count == 1) ? "tool" : "tools"} called]"
    end

    # Frames the transcript as a user message for the LLM.
    #
    # @param transcript [String] the rendered eviction + context transcript
    # @return [Array<Hash>] single-element messages array
    def build_messages(transcript)
      goals_context = active_goals_section

      content = <<~MSG.strip
        Here is the viewport of the main session:

        #{transcript}
        #{goals_context}
        Review the eviction zone and decide whether to save a snapshot or signal everything_ok.
      MSG

      [{role: "user", content:}]
    end

    # Builds the tool registry with eviction zone range for SaveSnapshot.
    #
    # @param eviction [Array<Message>] eviction zone messages
    # @return [Tools::Registry]
    def build_registry(eviction)
      registry = ::Tools::Registry.new(context: {
        main_session: @session,
        from_message_id: eviction.first.id,
        to_message_id: eviction.last.id
      })
      TOOLS.each { |tool| registry.register(tool) }
      registry
    end

    # Advances the boundary past the eviction zone to the first eligible
    # conversation/think message after it. If the session went quiet after
    # the zone, falls back to the last message in the eviction zone.
    #
    # @param eviction [Array<Message>] eviction zone messages
    def advance_boundary(eviction)
      return if eviction.empty?

      last_evicted_id = eviction.last.id
      new_boundary = @session.messages
        .where("id > ?", last_evicted_id)
        .order(:id)
        .find { |msg| msg.conversation_or_think? }

      new_boundary ||= eviction.last
      @session.update_column(:mneme_boundary_message_id, new_boundary.id)
      log.debug("session=#{@session.id} — boundary advanced to message #{new_boundary.id}")
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

    # @return [String, nil] formatted pin list, or nil when nothing is pinned
    def format_existing_pins
      pins = @session.pinned_messages.includes(:goals).order(:message_id)
      return nil if pins.empty?

      pins.map { |pin| format_pin_for_mneme(pin) }.join("\n")
    end

    # @param pin [PinnedMessage] pin with preloaded goals
    # @return [String]
    def format_pin_for_mneme(pin)
      goal_ids = pin.goals.map(&:id).join(", ")
      "  message #{pin.message_id} → goals [#{goal_ids}]"
    end

    # @return [Logger]
    def log = Mneme.logger
  end
end
