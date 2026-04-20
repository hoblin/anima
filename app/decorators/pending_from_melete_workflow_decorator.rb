# frozen_string_literal: true

# Decorates a +from_melete_workflow+ {PendingMessage} — a workflow that
# Melete activated for the upcoming turn. See
# {PendingFromMeleteSkillDecorator} for the parallel design — only the
# +kind+ field and badge label differ.
class PendingFromMeleteWorkflowDecorator < PendingMessageDecorator
  KIND = "workflow"

  # @return [nil] Melete activations are hidden in basic mode
  def render_basic
    nil
  end

  # @return [Hash] dimmed Melete-workflow activation payload
  def render_verbose
    {
      role: :pending_melete,
      kind: KIND,
      source: source_name,
      content: truncate_lines(content, max_lines: 3),
      status: "pending"
    }
  end

  # @return [Hash] full Melete-workflow activation payload
  def render_debug
    {
      role: :pending_melete,
      kind: KIND,
      source: source_name,
      content: content,
      status: "pending"
    }
  end

  # @return [String] Melete transcript line (header only — content is the workflow body)
  def render_melete
    "Melete activated workflow: #{source_name}"
  end
end
