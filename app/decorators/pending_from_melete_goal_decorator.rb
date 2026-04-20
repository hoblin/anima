# frozen_string_literal: true

# Decorates a +from_melete_goal+ {PendingMessage} — a goal event Melete
# logged for the upcoming turn (created/updated/closed). See
# {PendingFromMeleteSkillDecorator} for the parallel design.
class PendingFromMeleteGoalDecorator < PendingMessageDecorator
  KIND = "goal"

  # @return [nil] Melete activations are hidden in basic mode
  def render_basic
    nil
  end

  # @return [Hash] dimmed Melete-goal activation payload
  def render_verbose
    {
      role: :pending_melete,
      kind: KIND,
      source: source_name,
      content: truncate_lines(content, max_lines: 3),
      status: "pending"
    }
  end

  # @return [Hash] full Melete-goal activation payload
  def render_debug
    {
      role: :pending_melete,
      kind: KIND,
      source: source_name,
      content: content,
      status: "pending"
    }
  end

  # @return [String] Melete transcript line — goal id and content
  def render_melete
    "Melete logged goal #{source_name}: #{truncate_middle(content)}"
  end
end
