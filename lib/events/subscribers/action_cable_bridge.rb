# frozen_string_literal: true

module Events
  module Subscribers
    # Forwards EventBus events to Action Cable, bridging internal pub/sub
    # to external WebSocket clients. Each event is broadcast to the
    # session-specific stream (e.g. "session_42"), matching the stream
    # name used by {SessionChannel}.
    #
    # Only events with a valid session_id are broadcast — events without
    # one have no destination channel and are silently skipped.
    #
    # @example
    #   Events::Bus.subscribe(Events::Subscribers::ActionCableBridge.instance)
    #   # Now all events with session_id flow to "session_<id>" streams
    class ActionCableBridge
      include Events::Subscriber
      include Singleton

      # Receives a Rails.event notification hash and broadcasts the payload
      # to the session's Action Cable stream.
      #
      # @param event [Hash] with :payload containing event data including :session_id
      def emit(event)
        payload = event[:payload]
        return unless payload.is_a?(Hash)

        session_id = payload[:session_id]
        return if session_id.nil?

        ActionCable.server.broadcast("session_#{session_id}", payload)
      end
    end
  end
end
