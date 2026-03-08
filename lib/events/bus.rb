# frozen_string_literal: true

module Events
  # Central event bus built on Rails Structured Event Reporter.
  # All Anima events flow through here — subsystems emit events and
  # subscribers react independently without coupling.
  #
  # @example Emitting an event
  #   Events::Bus.emit(Events::UserMessage.new(content: "Hello"))
  #
  # @example Subscribing
  #   subscriber = MySubscriber.new
  #   Events::Bus.subscribe(subscriber)
  module Bus
    NAMESPACE = "anima"

    class << self
      def emit(event)
        Rails.event.notify(event.event_name, event.to_h)
      end

      def subscribe(subscriber, &filter)
        Rails.event.subscribe(subscriber, &filter)
      end

      def unsubscribe(subscriber)
        Rails.event.unsubscribe(subscriber)
      end
    end
  end
end
