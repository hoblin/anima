# frozen_string_literal: true

# Decorates tool_call events for display in the TUI.
# Hidden in basic mode — tool activity is represented by the
# aggregated tool counter instead.
class ToolCallDecorator < EventDecorator
  # @return [nil] tool calls are hidden in basic mode
  def render_basic
    nil
  end
end
