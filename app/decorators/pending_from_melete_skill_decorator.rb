# frozen_string_literal: true

# Decorates a +from_melete_skill+ {PendingMessage} — a skill that Melete
# activated for the upcoming turn. Promotes into a phantom
# +from_melete_skill+ tool_call/tool_response pair so the LLM sees it as
# its own past invocation; while pending, it shows in the TUI as a
# Melete badge so the user knows the skill is about to enter context.
#
# TUI rendering shape lives in {PendingFromMeleteDecorator} — only the
# +KIND+ constant and the Melete transcript line differ across the
# skill/workflow/goal trio.
class PendingFromMeleteSkillDecorator < PendingFromMeleteDecorator
  KIND = "skill"

  # @return [String] Melete transcript line (header only — content is the skill body)
  def render_melete
    "Melete activated skill: #{source_name}"
  end
end
