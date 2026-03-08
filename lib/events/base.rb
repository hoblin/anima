# frozen_string_literal: true

module Events
  # Base class for all Anima events. Subclasses must implement #type
  # returning a string identifier (e.g. "user_message").
  #
  # Events are POROs — they carry typed payloads through the event bus.
  # Persistence is a separate concern handled by ActiveRecord models.
  #
  # @abstract Subclass and implement {#type}
  class Base
    attr_reader :content, :session_id, :timestamp

    # @param content [String] event payload content
    # @param session_id [String, nil] optional session identifier
    def initialize(content:, session_id: nil)
      @content = content
      @session_id = session_id
      @timestamp = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
    end

    # @return [String] event type identifier
    # @raise [NotImplementedError] if subclass does not implement
    def type
      raise NotImplementedError, "#{self.class} must implement #type"
    end

    # @return [String] namespaced event name for Rails.event (e.g. "anima.user_message")
    def event_name
      "#{Bus::NAMESPACE}.#{type}"
    end

    # @return [Hash] serialized event payload
    def to_h
      {type: type, content: content, session_id: session_id, timestamp: timestamp}
    end
  end
end
