# frozen_string_literal: true

module Events
  module Subscribers
    # Persists all events to SQLite as they flow through the event bus.
    # Each event is written as an Event record belonging to the active session.
    #
    # @example
    #   session = Session.create!
    #   persister = Events::Subscribers::Persister.new(session)
    #   Events::Bus.subscribe(persister)
    class Persister
      include Events::Subscriber

      attr_reader :session

      def initialize(session)
        @session = session
        @mutex = Mutex.new
      end

      # Receives a Rails.event notification hash and persists it.
      # @param event [Hash] with :payload containing event data
      def emit(event)
        payload = event[:payload]
        return unless payload.is_a?(Hash)

        event_type = payload[:type]
        return if event_type.nil?

        @mutex.synchronize do
          @session.events.create!(
            event_type: event_type,
            payload: payload,
            timestamp: payload[:timestamp] || Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
          )
        end
      end

      def session=(new_session)
        @mutex.synchronize { @session = new_session }
      end
    end
  end
end
