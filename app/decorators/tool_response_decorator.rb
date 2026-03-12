# frozen_string_literal: true

# Renders tool result events.
# Hidden in basic mode — counter aggregation is a rendering concern
# handled by the Chat screen, not a per-event concern.
class ToolResponseDecorator < EventDecorator
  # @return [nil] hidden in basic mode
  def render_basic
    nil
  end
end
