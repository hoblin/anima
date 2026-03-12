# frozen_string_literal: true

# Decorates tool_response events for display in the TUI.
# Hidden in basic mode — tool activity is represented by the
# aggregated tool counter instead.
class ToolResponseDecorator < EventDecorator
  # @return [nil] tool responses are hidden in basic mode
  def render_basic
    nil
  end
end
