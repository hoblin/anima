# frozen_string_literal: true

# Base decorator for {Event} records, providing multi-resolution rendering
# for the TUI. Each event type has a dedicated subclass that implements
# rendering methods for each view mode (basic, verbose, debug).
#
# Decorators are applied server-side before broadcasting via ActionCable —
# the TUI receives pre-rendered text and never loads Draper.
#
# Subclasses must override {#render_basic}. Verbose and debug modes
# delegate to basic until subclasses provide their own implementations.
#
# @example Decorate an Event AR model
#   decorator = EventDecorator.for(event)
#   decorator.render_basic  #=> ["You: hello"] or nil
#
# @example Render for a specific view mode
#   decorator = EventDecorator.for(event)
#   decorator.render("verbose")  #=> ["You: hello"] (falls back to basic)
#
# @example Decorate a raw payload hash (from EventBus)
#   decorator = EventDecorator.for(type: "user_message", content: "hello")
#   decorator.render_basic  #=> ["You: hello"]
class EventDecorator < ApplicationDecorator
  delegate_all

  DECORATOR_MAP = {
    "user_message" => "UserMessageDecorator",
    "agent_message" => "AgentMessageDecorator",
    "tool_call" => "ToolCallDecorator",
    "tool_response" => "ToolResponseDecorator",
    "system_message" => "SystemMessageDecorator"
  }.freeze
  private_constant :DECORATOR_MAP

  # Normalizes hash payloads into an Event-like interface so decorators
  # can use {#payload}, {#event_type}, etc. uniformly on both AR models
  # and raw EventBus hashes.
  #
  # @!attribute event_type [r] the event's type (e.g. "user_message")
  # @!attribute payload [r] string-keyed hash of event data
  # @!attribute timestamp [r] nanosecond-precision timestamp
  # @!attribute token_count [r] cumulative token count
  EventPayload = Struct.new(:event_type, :payload, :timestamp, :token_count, keyword_init: true)

  # Factory returning the appropriate subclass decorator for the given event.
  # Hashes are normalized via {EventPayload} to provide a uniform interface.
  #
  # @param event [Event, Hash] an Event AR model or a raw payload hash
  # @return [EventDecorator, nil] decorated event, or nil for unknown types
  def self.for(event)
    source = wrap_source(event)
    klass_name = DECORATOR_MAP[source.event_type]
    return nil unless klass_name

    klass_name.constantize.new(source)
  end

  # Dispatches to the render method for the given view mode.
  #
  # @param mode [String] one of "basic", "verbose", "debug"
  # @return [Array<String>, nil] lines to display, or nil to hide the event
  def render(mode)
    send("render_#{mode}")
  end

  # @abstract Subclasses must implement to render the event for basic view mode.
  # @return [Array<String>, nil] lines to display, or nil to hide the event
  def render_basic
    raise NotImplementedError, "#{self.class} must implement #render_basic"
  end

  # Verbose view mode with timestamps and tool details.
  # Delegates to {#render_basic} until subclasses provide their own implementations.
  # @return [Array<String>, nil] lines to display, or nil to hide the event
  def render_verbose
    render_basic
  end

  # Debug view mode with token counts and system prompts.
  # Delegates to {#render_basic} until subclasses provide their own implementations.
  # @return [Array<String>, nil] lines to display, or nil to hide the event
  def render_debug
    render_basic
  end

  private

  # Extracts display content from the event payload.
  # @return [String, nil]
  def content
    payload["content"]
  end

  # Normalizes input to something Draper can wrap.
  # Event AR models pass through; hashes become EventPayload structs
  # with string-normalized keys.
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
