# frozen_string_literal: true

# Renders internal system notification events.
# Hidden in basic mode — system messages are internal plumbing.
class SystemMessageDecorator < EventDecorator
  # @return [nil] hidden in basic mode
  def render_basic
    nil
  end
end
