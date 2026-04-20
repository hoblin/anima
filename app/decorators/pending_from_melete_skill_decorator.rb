# frozen_string_literal: true

# Decorates a +from_melete_skill+ {PendingMessage} — a skill that Melete
# activated for the upcoming turn. Promotes into a phantom
# +from_melete_skill+ tool_call/tool_response pair so the LLM sees it as
# its own past invocation; while pending, it shows in the TUI as a
# Melete badge so the user knows the skill is about to enter context.
#
# Hidden in basic. Visible from verbose with a +[Melete skill: <name>]+ badge.
class PendingFromMeleteSkillDecorator < PendingMessageDecorator
  KIND = "skill"

  # @return [nil] Melete activations are hidden in basic mode
  def render_basic
    nil
  end

  # @return [Hash] dimmed Melete-skill activation payload
  def render_verbose
    {
      role: :pending_melete,
      kind: KIND,
      source: source_name,
      content: truncate_lines(content, max_lines: 3),
      status: "pending"
    }
  end

  # @return [Hash] full Melete-skill activation payload
  def render_debug
    {
      role: :pending_melete,
      kind: KIND,
      source: source_name,
      content: content,
      status: "pending"
    }
  end

  # @return [String] Melete transcript line (header only — content is the skill body)
  def render_melete
    "Melete activated skill: #{source_name}"
  end
end
