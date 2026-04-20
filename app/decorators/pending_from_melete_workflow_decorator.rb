# frozen_string_literal: true

# Decorates a +from_melete_workflow+ {PendingMessage} — a workflow that
# Melete activated for the upcoming turn. See
# {PendingFromMeleteDecorator} for the shared TUI rendering shape.
class PendingFromMeleteWorkflowDecorator < PendingFromMeleteDecorator
  KIND = "workflow"

  # @return [String] Melete transcript line (header only — content is the workflow body)
  def render_melete
    "Melete activated workflow: #{source_name}"
  end
end
