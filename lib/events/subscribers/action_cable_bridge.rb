# frozen_string_literal: true

module Events
  module Subscribers
    # Forwards EventBus events to Action Cable, bridging internal pub/sub
    # to external WebSocket clients. Each event is broadcast to the
    # session-specific stream (e.g. "session_42"), matching the stream
    # name used by {SessionChannel}.
    #
    # Events are decorated via {EventDecorator} before broadcast, adding
    # pre-rendered text for each view mode. The TUI receives ready-to-display
    # strings and never loads Draper.
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

      # Receives a Rails.event notification hash, decorates the payload
      # with rendered output, and broadcasts to the session's Action Cable stream.
      #
      # @param event [Hash] with :payload containing event data including :session_id
      def emit(event)
        payload = event[:payload]
        return unless payload.is_a?(Hash)

        session_id = payload[:session_id]
        return if session_id.nil?

        ActionCable.server.broadcast("session_#{session_id}", decorate_payload(payload))
      end

      private

      # Decorates the payload hash with pre-rendered output for each view mode.
      # Uses string keys for the +rendered+ hash to match JSON wire format.
      # Falls back to the raw payload if decoration fails.
      def decorate_payload(payload)
        decorator = EventDecorator.for(payload)
        return payload unless decorator

        payload.merge("rendered" => {"basic" => decorator.render_basic})
      end
    end
  end
end
