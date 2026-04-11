# frozen_string_literal: true

# Base decorator for {Message} records, providing multi-resolution rendering
# for the TUI and analytical brain. Each message type has a dedicated subclass
# that implements rendering methods for each view mode:
#
# - **basic** / **verbose** / **debug** — TUI display modes returning structured hashes
# - **brain** — analytical brain transcript returning plain strings (or nil to skip)
#
# TUI decorators return structured hashes (not pre-formatted strings) so that
# the TUI can style and lay out content based on semantic role, without
# fragile regex parsing. The TUI receives structured data via ActionCable
# and formats it for display.
#
# Brain mode returns condensed single-line strings for the analytical brain's
# message transcript. Returns nil to exclude a message from the brain's view.
#
# Subclasses must override {#render_basic}. Verbose, debug, and brain modes
# delegate to basic until subclasses provide their own implementations.
#
# Instantiate via +message.decorate+ — {Message#decorator_class} picks the
# concrete subclass based on +message_type+.
#
# @example Decorate a message and render it
#   decorator = message.decorate
#   decorator.render("basic")  #=> {role: :user, content: "hello"} or nil
class MessageDecorator < ApplicationDecorator
  delegate_all

  TOOL_ICON = "\u{1F527}"
  RETURN_ARROW = "\u21A9"
  ERROR_ICON = "\u274C"
  MIDDLE_TRUNCATION_MARKER = "\n[...truncated...]\n"

  RENDER_DISPATCH = {
    "basic" => :render_basic,
    "verbose" => :render_verbose,
    "debug" => :render_debug,
    "brain" => :render_brain,
    "mneme" => :render_mneme
  }.freeze
  private_constant :RENDER_DISPATCH

  # Dispatches to the render method for the given view mode.
  #
  # @param mode [String] one of "basic", "verbose", "debug", "brain", "mneme"
  # @return [Hash, String, nil] structured message data (basic/verbose/debug),
  #   plain string (brain), or nil to hide the message
  # @raise [ArgumentError] if the mode is not a valid view mode
  def render(mode)
    method = RENDER_DISPATCH[mode]
    raise ArgumentError, "Invalid view mode: #{mode.inspect}" unless method

    public_send(method)
  end

  # @abstract Subclasses must implement to render the message for basic view mode.
  # @return [Hash, nil] structured message data, or nil to hide the message
  def render_basic
    raise NotImplementedError, "#{self.class} must implement #render_basic"
  end

  # Verbose view mode with timestamps and tool details.
  # Delegates to {#render_basic} until subclasses provide their own implementations.
  # @return [Hash, nil] structured message data, or nil to hide the message
  def render_verbose
    render_basic
  end

  # Debug view mode with token counts and system prompts.
  # Delegates to {#render_basic} until subclasses provide their own implementations.
  # @return [Hash, nil] structured message data, or nil to hide the message
  def render_debug
    render_basic
  end

  # Analytical brain view — condensed single-line string for the brain's
  # message transcript. Returns nil to exclude from the brain's context.
  # Subclasses override to provide message-type-specific formatting.
  # @return [String, nil] formatted transcript line, or nil to skip
  def render_brain
    nil
  end

  # Mneme memory view — transcript line for eviction/context zones.
  # Conversation and think messages return a prefixed string.
  # Regular tool calls return +:tool_call+ (counter marker).
  # Tool responses return +nil+ (silent).
  # @return [String, Symbol, nil]
  def render_mneme
    nil
  end

  private

  # Token count for display: heuristic estimate seeded by the
  # {TokenEstimation} callback, refined later by {CountTokensJob}.
  #
  # @return [Hash] `{tokens: Integer}`
  def token_info
    {tokens: token_count.to_i}
  end

  # Extracts display content from the message payload.
  # @return [String, nil]
  def content
    payload["content"]
  end

  # Truncates multi-line text, appending "..." when lines exceed the limit.
  # @param text [String, nil] text to truncate (nil is coerced to empty string)
  # @param max_lines [Integer] maximum number of lines to keep
  # @return [String] truncated text
  def truncate_lines(text, max_lines:)
    str = text.to_s
    lines = str.split("\n")
    return str unless lines.size > max_lines

    lines.first(max_lines).push("...").join("\n")
  end

  # Truncates long text by cutting the middle, preserving the start and end
  # so context and conclusions aren't lost. Used for brain transcripts where
  # both the opening (intent) and closing (result) matter.
  #
  # @param text [String, nil] text to truncate
  # @param max_chars [Integer] maximum character length before truncation
  # @return [String] original text or start + marker + end
  def truncate_middle(text, max_chars: 500)
    str = text.to_s
    return str if str.length <= max_chars

    keep = max_chars - MIDDLE_TRUNCATION_MARKER.length
    head = keep / 2
    tail = keep - head
    "#{str[0, head]}#{MIDDLE_TRUNCATION_MARKER}#{str[-tail, tail]}"
  end
end
