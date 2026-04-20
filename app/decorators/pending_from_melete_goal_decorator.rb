# frozen_string_literal: true

# Decorates a +from_melete_goal+ {PendingMessage} — a goal event Melete
# logged for the upcoming turn (created/updated/closed). See
# {PendingFromMeleteDecorator} for the shared TUI rendering shape.
class PendingFromMeleteGoalDecorator < PendingFromMeleteDecorator
  KIND = "goal"

  # @return [String] Melete transcript line — goal id and content
  def render_melete
    "Melete logged goal #{source_name}: #{truncate_middle(content)}"
  end
end
