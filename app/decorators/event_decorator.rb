# frozen_string_literal: true

# Base decorator for all event types in the system.
# Wraps raw event payload hashes (from WebSocket or Event#payload) and provides
# a polymorphic rendering API. Each subclass implements view-mode-specific methods
# that return plain strings — the rendering framework applies styling separately.
#
# @example Decorate a WebSocket event payload
#   decorator = EventDecorator.for({"type" => "user_message", "content" => "hello"})
#   decorator.render_basic  #=> ["You: hello"]
#
# @example Hidden events return nil
#   decorator = EventDecorator.for({"type" => "tool_call", "content" => "bash"})
#   decorator.render_basic  #=> nil
class EventDecorator < ApplicationDecorator
  DECORATOR_MAP = {
    "user_message" => "UserMessageDecorator",
    "agent_message" => "AgentMessageDecorator",
    "tool_call" => "ToolCallDecorator",
    "tool_response" => "ToolResponseDecorator",
    "system_message" => "SystemMessageDecorator"
  }.freeze

  # Factory method that returns the correct subclass for the given event data.
  #
  # @param event_data [Hash] raw event payload with "type" and "content" keys
  # @param context [Hash] additional rendering context (e.g. view mode settings)
  # @return [EventDecorator] subclass instance appropriate for the event type
  # @raise [ArgumentError] if event_data has an unknown "type"
  def self.for(event_data, context: {})
    event_type = event_data["type"]
    class_name = DECORATOR_MAP.fetch(event_type) do
      raise ArgumentError, "Unknown event type: #{event_type.inspect}"
    end
    Object.const_get(class_name).new(event_data, context: context)
  end

  # Renders the event for basic (default) view mode.
  # @return [Array<String>] lines to display, or nil if hidden in this mode
  def render_basic
    raise NotImplementedError, "#{self.class}#render_basic must be implemented"
  end

  # Renders the event for verbose view mode (includes tool calls, timestamps).
  # @return [Array<String>] lines to display, or nil if hidden
  # @raise [NotImplementedError] until verbose mode ticket lands
  def render_verbose
    raise NotImplementedError, "#{self.class}#render_verbose is not yet implemented"
  end

  # Renders the event for debug view mode (full LLM context, token counts).
  # @return [Array<String>] lines to display, or nil if hidden
  # @raise [NotImplementedError] until debug mode ticket lands
  def render_debug
    raise NotImplementedError, "#{self.class}#render_debug is not yet implemented"
  end

  # @return [String, nil] display label for styling (e.g. "You", "Anima")
  def label
    nil
  end

  # @return [Symbol, nil] role identifier for styling (:user, :assistant, nil)
  def role
    nil
  end

  private

  # @return [String, nil] the event's text content
  def content
    object["content"]
  end

  # @return [String] the event type string (e.g. "user_message")
  def event_type
    object["type"]
  end

  # @return [Integer, nil] nanosecond timestamp from the event payload
  def timestamp
    object["timestamp"]
  end

  # Shared rendering for message subclasses that prepend a label to content.
  # First line gets "Label: content", remaining lines are bare content.
  # @return [Array<String>] rendered lines
  def render_labeled_content
    content_lines = content.to_s.split("\n", -1)
    ["#{label}: #{content_lines.first}"] + content_lines.drop(1)
  end
end
