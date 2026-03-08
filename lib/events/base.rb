# frozen_string_literal: true

module Events
  class Base
    attr_reader :content, :session_id, :timestamp

    def initialize(content:, session_id: nil)
      @content = content
      @session_id = session_id
      @timestamp = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
    end

    def type
      raise NotImplementedError, "#{self.class} must implement #type"
    end

    def event_name
      "anima.#{type}"
    end

    def to_h
      {type: type, content: content, session_id: session_id, timestamp: timestamp}
    end
  end
end
