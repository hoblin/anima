# frozen_string_literal: true

# Decorates a +from_mneme+ {PendingMessage} — an associative recall
# enqueued by Mneme that will become a phantom +from_mneme+
# tool_call/tool_response pair on promotion. Background-kind, so it
# rides the next active drain instead of triggering one.
#
# Hidden in basic. Visible from verbose with a +[Mneme recall]+ badge.
class PendingFromMnemeDecorator < PendingMessageDecorator
  # @return [nil] Mneme recalls are hidden in basic mode
  def render_basic
    nil
  end

  # @return [Hash] dimmed Mneme recall payload
  def render_verbose
    {
      role: :pending_mneme,
      content: truncate_lines(content, max_lines: 3),
      status: "pending"
    }
  end

  # @return [Hash] full Mneme recall payload
  def render_debug
    {
      role: :pending_mneme,
      content: content,
      status: "pending"
    }
  end

  # @return [String] Melete transcript line — Mneme recalls become part
  #   of Melete's extended-context view (her "what's about to land" peek).
  def render_melete
    "Mneme recalled (pending): #{truncate_middle(content)}"
  end
end
