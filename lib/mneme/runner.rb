# frozen_string_literal: true

module Mneme
  # Mneme in eviction mode — a phantom LLM loop that summarizes the oldest
  # slice of the viewport before it slides off. She sees the eviction zone
  # (what she's compressing) plus the remaining viewport (context she needs
  # to write a faithful summary), calls {Tools::SaveSnapshot} to persist
  # the compressed memory, optionally pins critical messages to goals, then
  # advances the Mneme boundary past the zone so the cycle repeats as more
  # messages accumulate.
  #
  # @example
  #   Mneme::Runner.new(session).call
  class Runner < BaseRunner
    TOOLS = [
      Tools::SaveSnapshot,
      Tools::AttachMessagesToGoals,
      Tools::EverythingOk
    ].freeze

    TASK_PROMPT = <<~PROMPT
      Right now your work is compression. As Aoide's viewport slides forward, you catch what's about to fall off and turn it into something she can carry.

      ──────────────────────────────
      WHAT YOU SEE
      ──────────────────────────────
      Two sections of the viewport, oldest to newest:
      - EVICTION ZONE: about to fall off. This is what you summarize.
      - CONTEXT: the live viewport past the eviction zone. Use it for continuity — Aoide is still seeing it.

      Messages are prefixed with `message N` (database ID, used for pinning).
      Tool calls are compressed to `[N tools called]` — focus on conversation, not mechanical work.

      ──────────────────────────────
      HOW TO REMEMBER
      ──────────────────────────────
      Summarize the eviction zone with save_snapshot: what was discussed and decided, why, goal progress, and the context Aoide will need later. Paraphrase — don't quote verbatim. Drop mechanical steps.

      A snapshot is a tax on Aoide's viewport budget. Every word you write takes a word she can't spend on the current exchange. Capture the load-bearing details; let the rest go.

      Pin critical messages to goals with attach_messages_to_goals when exact wording matters — user instructions, key corrections, key decisions. A pinned message survives eviction intact. Use it sparingly: each pin is another slice of viewport Aoide carries forward.

      If the eviction zone holds only mechanical activity — tool calls, no conversation — call everything_ok and let it fall off without a snapshot.

      save_snapshot and attach_messages_to_goals can be called together in one turn.
    PROMPT

    private

    def task_prompt = TASK_PROMPT

    def user_messages
      eviction = @eviction ||= session.eviction_zone_messages
      context = @context ||= session.viewport_messages.where("messages.id > ?", eviction.last.id)
      transcript = render_transcript(eviction, context)
      goals = active_goals_section

      log.info("session=#{session.id} — eviction (#{eviction.size} eviction + #{context.size} context)")
      log.debug("compressed viewport:\n#{transcript}")

      content = <<~MSG.strip
        Here is Aoide's viewport:

        #{transcript}
        #{goals}
        Review the eviction zone and summarize it with save_snapshot.
        If the zone holds only mechanical activity, call everything_ok.
      MSG

      [{role: "user", content: content}]
    end

    def build_registry
      eviction = @eviction ||= session.eviction_zone_messages
      registry = ::Tools::Registry.new(context: {
        main_session: session,
        from_message_id: session.mneme_boundary_message_id,
        to_message_id: eviction.last.id
      })
      TOOLS.each { |tool| registry.register(tool) }
      registry
    end

    def after_call(_result)
      eviction = @eviction or return
      last_evicted_id = eviction.last.id

      new_boundary_id = session.messages
        .conversation_or_think
        .where("id > ?", last_evicted_id)
        .order(:id)
        .pick(:id) || last_evicted_id

      session.update_column(:mneme_boundary_message_id, new_boundary_id)
      Events::Bus.emit(Events::EvictionCompleted.new(
        session_id: session.id,
        evict_above_id: last_evicted_id
      ))
      log.debug("session=#{session.id} — boundary advanced to message #{new_boundary_id}")
    end

    # Renders eviction zone and context as a Mneme transcript using
    # message decorators. Tool calls are compressed into counters.
    def render_transcript(eviction, context)
      [
        "── EVICTION ZONE ──",
        render_messages(eviction),
        "── CONTEXT ──",
        render_messages(context)
      ].join("\n")
    end

    # Renders messages using decorators, compressing consecutive
    # tool calls into `[N tools called]` counters.
    def render_messages(messages)
      lines = []
      tool_count = 0

      messages.each do |message|
        rendered = message.decorate.render("mneme")

        case rendered
        when :tool_call
          tool_count += 1
        when nil
          next
        else
          lines << flush_tool_count(tool_count) if tool_count > 0
          tool_count = 0
          lines << rendered
        end
      end

      lines << flush_tool_count(tool_count) if tool_count > 0
      lines.join("\n")
    end

    def flush_tool_count(count)
      "[#{count} #{(count == 1) ? "tool" : "tools"} called]"
    end

    # Active-goals block so Mneme knows what Goals exist, which messages
    # are already pinned, and can reference them when deciding what to
    # pin or summarize.
    def active_goals_section
      root_goals = session.goals.root.includes(:sub_goals).active.order(:created_at)
      return "" if root_goals.empty?

      lines = root_goals.map { |goal| format_goal(goal) }
      pinned = format_existing_pins

      section = "\n\n🎯 Active Goals\n#{lines.join("\n")}\n"
      section += "\n📌 Already Pinned\n#{pinned}\n" if pinned
      section
    end

    def format_goal(goal)
      parts = ["  ● #{goal.description} (id: #{goal.id})"]
      goal.sub_goals.each do |sub|
        checkbox = sub.completed? ? "[x]" : "[ ]"
        parts << "    #{checkbox} #{sub.description} (id: #{sub.id})"
      end
      parts.join("\n")
    end

    def format_existing_pins
      pins = session.pinned_messages.includes(:goals).order(:message_id)
      return nil if pins.empty?

      pins.map { |pin|
        goal_ids = pin.goals.map(&:id).join(", ")
        "  message #{pin.message_id} → goals [#{goal_ids}]"
      }.join("\n")
    end
  end
end
