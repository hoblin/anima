# frozen_string_literal: true

# Base decorator for {PendingMessage} records, providing multi-resolution
# rendering for the TUI ("basic" / "verbose" / "debug") and for the
# enrichment subsystems Mneme and Melete.
#
# Each PM type has a dedicated subclass that mirrors the visual treatment
# of its promoted-{Message} counterpart, with +status: "pending"+ added
# so the TUI can render it dimmed.
#
# Subclasses must override {#render_basic}. Verbose, debug, melete, and
# mneme delegate to basic until subclasses provide their own
# implementations.
#
# Instantiate via +pending_message.decorate+ — {PendingMessage#decorator_class}
# picks the concrete subclass based on +message_type+.
class PendingMessageDecorator < ApplicationDecorator
  delegate_all

  RENDER_DISPATCH = {
    "basic" => :render_basic,
    "verbose" => :render_verbose,
    "debug" => :render_debug,
    "melete" => :render_melete,
    "mneme" => :render_mneme
  }.freeze
  private_constant :RENDER_DISPATCH

  # Dispatches to the render method for the given view mode.
  #
  # @param mode [String] one of "basic", "verbose", "debug", "melete", "mneme"
  # @return [Hash, String, nil] structured TUI payload, transcript line, or nil to hide
  # @raise [ArgumentError] if the mode is not supported
  def render(mode)
    method = RENDER_DISPATCH[mode]
    raise ArgumentError, "Invalid view mode: #{mode.inspect}" unless method

    public_send(method)
  end

  # @abstract Subclasses must implement to render the pending message for basic view mode.
  # @return [Hash, nil] structured payload, or nil to hide
  def render_basic
    raise NotImplementedError, "#{self.class} must implement #render_basic"
  end

  # @return [Hash, nil] verbose payload (defaults to basic)
  def render_verbose
    render_basic
  end

  # @return [Hash, nil] debug payload (defaults to verbose)
  def render_debug
    render_verbose
  end

  # @return [String, nil] Melete transcript line, or nil to skip
  def render_melete
    nil
  end

  # @return [String, nil] Mneme transcript line, or nil to skip
  def render_mneme
    nil
  end

  protected

  MIDDLE_TRUNCATION_MARKER = MessageDecorator::MIDDLE_TRUNCATION_MARKER

  # Mirror of {MessageDecorator#truncate_middle} — duplicated here rather than
  # inherited to keep the two decorator families independent.
  def truncate_middle(text, max_chars: 500)
    str = text.to_s
    return str if str.length <= max_chars

    keep = max_chars - MIDDLE_TRUNCATION_MARKER.length
    head = keep / 2
    tail = keep - head
    "#{str[0, head]}#{MIDDLE_TRUNCATION_MARKER}#{str[-tail, tail]}"
  end

  # Mirror of {MessageDecorator#truncate_lines}.
  def truncate_lines(text, max_lines:)
    str = text.to_s
    lines = str.split("\n")
    return str unless lines.size > max_lines

    lines.first(max_lines).push("...").join("\n")
  end
end
