# frozen_string_literal: true

# Decorates system_message events for display in the TUI.
# Hidden in basic mode — system messages are internal events
# not shown to users.
class SystemMessageDecorator < EventDecorator
  # @return [nil] system messages are hidden in basic mode
  def render_basic
    nil
  end
end
