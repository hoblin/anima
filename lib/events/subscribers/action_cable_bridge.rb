# frozen_string_literal: true

module Events
  module Subscribers
    # Forwards EventBus events to Action Cable, bridging internal pub/sub
    # to external WebSocket clients. Each event is broadcast to the
    # session-specific stream (e.g. "session_42"), matching the stream
    # name used by {SessionChannel}.
    #
    # Events are decorated via {EventDecorator} before broadcast, adding
    # pre-rendered text for the session's current view mode. The TUI
    # receives ready-to-display strings and never loads Draper.
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
      # Loads the session to determine the current view_mode for decoration.
      #
      # @param event [Hash] with :payload containing event data including :session_id
      def emit(event)
        payload = event[:payload]
        return unless payload.is_a?(Hash)

        session_id = payload[:session_id]
        return if session_id.nil?

        mode = session_view_mode(session_id)
        ActionCable.server.broadcast("session_#{session_id}", decorate_payload(payload, mode))
      end

      private

      # Decorates the payload hash with pre-rendered output for the given view mode.
      # Uses string keys for the +rendered+ hash to match JSON wire format.
      # Falls back to the raw payload if decoration fails.
      def decorate_payload(payload, mode = "basic")
        decorator = EventDecorator.for(payload)
        return payload unless decorator

        payload.merge("rendered" => {mode => decorator.render(mode)})
      end

      # Looks up the session's current view_mode. Falls back to "basic"
      # if the session cannot be found (e.g. race condition during deletion).
      def session_view_mode(session_id)
        Session.where(id: session_id).pick(:view_mode) || "basic"
      end
    end
  end
end
