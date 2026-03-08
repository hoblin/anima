# frozen_string_literal: true

module Events
  # Central event bus built on Rails Structured Event Reporter.
  # All Anima events flow through here — subsystems emit events and
  # subscribers react independently without coupling.
  #
  # Subscribers must implement the {Subscriber} interface (#emit method).
  # Rails.event wraps payloads: subscribers receive a Hash with :name,
  # :payload (the event's to_h), and :timestamp keys.
  #
  # @example Emitting an event
  #   Events::Bus.emit(Events::UserMessage.new(content: "Hello"))
  #
  # @example Subscribing
  #   subscriber = MySubscriber.new  # must implement #emit(event_hash)
  #   Events::Bus.subscribe(subscriber)
  module Bus
    NAMESPACE = "anima"

    class << self
      # @param event [Events::Base] the event to broadcast
      def emit(event)
        Rails.event.notify(event.event_name, event.to_h)
      end

      # @param subscriber [#emit] object implementing the Subscriber interface
      # @param filter [Proc] optional filter block passed to Rails.event
      def subscribe(subscriber, &filter)
        Rails.event.subscribe(subscriber, &filter)
      end

      # @param subscriber [#emit] previously subscribed object
      def unsubscribe(subscriber)
        Rails.event.unsubscribe(subscriber)
      end
    end
  end
end
