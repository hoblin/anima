# frozen_string_literal: true

module Mneme
  # Mneme in recall mode — a phantom LLM loop that decides whether any older
  # memory would help Aoide with what she's working on now, and surfaces it
  # if so. Triggered whenever Aoide's context shifts in ways worth
  # re-remembering around (new user message, goal change).
  #
  # The muse searches long-term memory through her search tool (which
  # automatically excludes Aoide's current viewport), drills into candidate
  # messages when she needs to decide, and surfaces only what genuinely
  # helps. Silence — nothing surfaced — is the default answer.
  #
  # This is not the eviction loop ({Runner}); same muse, different work.
  #
  # @example
  #   Mneme::RecallRunner.new(session).call
  class RecallRunner < BaseRunner
    TOOLS = [
      ::Tools::SearchMessages,
      ::Tools::ViewMessages,
      Tools::SurfaceMemory,
      Tools::NothingToSurface
    ].freeze

    TASK_PROMPT = <<~PROMPT
      Right now your work is recall. Aoide's focus has just shifted — a new message, a changed goal — and you're here to decide whether any memory from before would genuinely help her now.

      ──────────────────────────────
      WHAT MAKES RECALL USEFUL
      ──────────────────────────────
      Recall is a tax on Aoide's viewport. Every memory you surface takes tokens away from the present exchange. Return empty-handed far more often than you return something. One well-chosen memory beats five that nearly-match. Most of the time, nothing is worth surfacing — and that is the right answer.

      A memory is worth surfacing when it carries weight Aoide can't reconstruct from what's already in front of her: a prior decision about this exact problem, a specific constraint she encountered before, a voice from another session relevant to the one unfolding. Not tangential echoes. Not mere keyword overlap. Something she'd want to have remembered.

      ──────────────────────────────
      THE QUERY IS THE JUDGMENT
      ──────────────────────────────
      Composing your query is where the thinking happens. Read what Aoide is doing right now and ask: what specific words, phrases, or names would only appear in past messages that meaningfully help her? Not the topic. Not the domain. The signal that distinguishes "she'd want this" from "this contains overlapping vocabulary."

      When a candidate looks promising but its meaning is unclear, read the full context around it before surfacing.
    PROMPT

    private

    def task_prompt = TASK_PROMPT

    def context_sections
      [active_goals_section, already_surfaced_section]
    end

    def user_messages
      trigger = recall_trigger_description
      content = <<~MSG.strip
        #{trigger}

        Decide whether any older memory would help Aoide now. Search if something comes to mind, drill down when you're unsure, surface only what earns its place. Finish with nothing_to_surface when you're done — even if you surface something.
      MSG
      [{role: "user", content: content}]
    end

    def build_registry
      registry = ::Tools::Registry.new(context: {
        session: session,
        main_session: session
      })
      TOOLS.each { |tool| registry.register(tool) }
      registry
    end

    # Describes what just changed in Aoide's context — the reason Mneme
    # woke. Today that's a goal list shift; the framing leaves room for
    # other triggers later without rewriting.
    def recall_trigger_description
      goals_lines = root_goals.map { |goal| format_goal(goal) }

      if goals_lines.empty?
        "Aoide's context shifted — no active goals right now. If nothing comes to mind about this session's trajectory, that's fine; call nothing_to_surface."
      else
        <<~MSG.strip
          Aoide's active goals right now:

          #{goals_lines.join("\n")}
        MSG
      end
    end

    # Active goals block for the system-prompt context. Same content as
    # the trigger's goal block — but mirroring it here lets future
    # non-goal triggers still give the muse a stable view of the goals.
    def active_goals_section
      return if root_goals.empty?

      lines = root_goals.map { |goal| format_goal(goal) }
      "\n\n🎯 Active Goals\n#{lines.join("\n")}"
    end

    # Memory IDs Mneme has surfaced recently whose phantom pairs still
    # sit in Aoide's viewport — so she doesn't surface the same thing
    # twice in one conversation. Search already filters by boundary;
    # this block makes the same constraint visible to the muse so she
    # can reason around it rather than being silently restricted.
    def already_surfaced_section
      surfaced_ids = surfaced_message_ids_in_viewport
      return if surfaced_ids.empty?

      "\n\n📚 Memories You've Already Surfaced This Cycle\nmessage ids: #{surfaced_ids.join(", ")}"
    end

    def root_goals
      @root_goals ||= session.goals.root.includes(:sub_goals).active.order(:created_at).to_a
    end

    def format_goal(goal)
      parts = ["  ● #{goal.description} (id: #{goal.id})"]
      goal.sub_goals.each do |sub|
        checkbox = sub.completed? ? "[x]" : "[ ]"
        parts << "    #{checkbox} #{sub.description} (id: #{sub.id})"
      end
      parts.join("\n")
    end

    def surfaced_message_ids_in_viewport
      session.viewport_messages
        .where(message_type: "tool_call")
        .where("payload ->> 'tool_name' = ?", PendingMessage::MNEME_TOOL)
        .pluck(Arel.sql("json_extract(payload, '$.tool_input.message_id')"))
        .compact
        .map(&:to_i)
    end
  end
end
