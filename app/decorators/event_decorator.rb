# frozen_string_literal: true

# Base decorator for {Event} records, providing multi-resolution rendering
# for the TUI. Each event type has a dedicated subclass that implements
# rendering methods for each view mode (basic, verbose, debug).
#
# Decorators are applied server-side before broadcasting via ActionCable —
# the TUI receives pre-rendered text and never loads Draper.
#
# @example Decorate an Event AR model
#   decorator = EventDecorator.for(event)
#   decorator.render_basic  #=> ["You: hello"] or nil
#
# @example Decorate a raw payload hash (from EventBus)
#   decorator = EventDecorator.for(type: "user_message", content: "hello")
#   decorator.render_basic  #=> ["You: hello"]
class EventDecorator < ApplicationDecorator
  delegate_all

  # Maps event_type strings to decorator class names.
  # Uses strings to avoid autoloading issues with Zeitwerk.
  DECORATOR_MAP = {
    "user_message" => "UserMessageDecorator",
    "agent_message" => "AgentMessageDecorator",
    "tool_call" => "ToolCallDecorator",
    "tool_response" => "ToolResponseDecorator",
    "system_message" => "SystemMessageDecorator"
  }.freeze

  DEFAULT_TRUNCATE_LENGTH = 200

  # Lightweight struct for decorating hash payloads without DB lookup.
  # Quacks like an Event AR model for the attributes decorators need.
  EventPayload = Struct.new(:event_type, :payload, :timestamp, :token_count, keyword_init: true)

  # Factory returning the appropriate subclass decorator for the given event.
  #
  # @param event [Event, Hash] an Event AR model or a raw payload hash
  # @return [EventDecorator, nil] decorated event, or nil for unknown types
  def self.for(event)
    source = wrap_source(event)
    klass_name = DECORATOR_MAP[source.event_type]
    return nil unless klass_name

    klass_name.constantize.new(source)
  end

  # Renders the event for basic view mode.
  # @return [Array<String>, nil] lines to display, or nil to hide the event
  def render_basic
    raise NotImplementedError, "#{self.class} must implement #render_basic"
  end

  # Renders the event for verbose view mode.
  # @raise [NotImplementedError] until verbose mode is implemented
  def render_verbose
    raise NotImplementedError, "Verbose mode not yet implemented"
  end

  # Renders the event for debug view mode.
  # @raise [NotImplementedError] until debug mode is implemented
  def render_debug
    raise NotImplementedError, "Debug mode not yet implemented"
  end

  private

  # Extracts display content from the event payload.
  # Handles both string-keyed (DB) and symbol-keyed (EventBus) hashes.
  # @return [String, nil]
  def content
    payload["content"] || payload[:content]
  end

  # Truncates text to a maximum length, appending an ellipsis if needed.
  # @param text [String] the text to truncate
  # @param max_length [Integer] maximum character count before truncation
  # @return [String]
  def truncate_text(text, max_length: DEFAULT_TRUNCATE_LENGTH)
    normalized = text.to_s
    return normalized if normalized.length <= max_length

    "#{normalized[0, max_length]}..."
  end

  # Formats the event timestamp as HH:MM:SS for display.
  # @return [String]
  def formatted_timestamp
    ts = object.timestamp
    return "" unless ts

    Time.at(0, ts, :nanosecond).strftime("%H:%M:%S")
  end

  # Normalizes input to something Draper can wrap.
  # Event AR models pass through; hashes become EventPayload structs.
  def self.wrap_source(event)
    return event unless event.is_a?(Hash)

    normalized = event.transform_keys(&:to_s)
    EventPayload.new(
      event_type: normalized["type"].to_s,
      payload: normalized,
      timestamp: normalized["timestamp"],
      token_count: normalized["token_count"]&.to_i || 0
    )
  end
  private_class_method :wrap_source
end
