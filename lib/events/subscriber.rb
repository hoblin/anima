# frozen_string_literal: true

module Events
  # Interface for event bus subscribers. Include this module and implement
  # #emit to receive Rails.event notifications.
  #
  # The #emit method receives a Hash from Rails Structured Event Reporter:
  #   { name: "anima.user_message",
  #     payload: { type: "user_message", content: "hello", ... },
  #     timestamp: <nanosecond Integer> }
  #
  # @example
  #   class MySubscriber
  #     include Events::Subscriber
  #
  #     def emit(event)
  #       content = event.dig(:payload, :content)
  #       # handle event...
  #     end
  #   end
  module Subscriber
    def emit(event)
      raise NotImplementedError, "#{self.class} must implement #emit"
    end
  end
end
