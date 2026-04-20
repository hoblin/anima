# frozen_string_literal: true

# Shared base for the three Melete-activation pending decorators (skill,
# workflow, goal). All three share the same TUI shape — a dimmed
# +pending_melete+ payload with +kind+ + +source+ + truncated content
# — and only differ on the +KIND+ constant and the per-type Melete
# transcript line. Subclasses override +KIND+ and +render_melete+; this
# base owns everything else.
class PendingFromMeleteDecorator < PendingMessageDecorator
  # @return [nil] Melete activations are hidden in basic mode
  def render_basic
    nil
  end

  # @return [Hash] dimmed Melete-activation payload
  def render_verbose
    {
      role: :pending_melete,
      kind: self.class::KIND,
      source: source_name,
      content: truncate_lines(content, max_lines: 3),
      status: "pending"
    }
  end

  # @return [Hash] full Melete-activation payload
  def render_debug
    {
      role: :pending_melete,
      kind: self.class::KIND,
      source: source_name,
      content: content,
      status: "pending"
    }
  end
end
