# frozen_string_literal: true

module Events
  module Subscribers
    # Bridges transient (non-persisted) events to ActionCable so clients
    # receive them over WebSocket. Persisted events reach clients via
    # {Event::Broadcasting} callbacks; this subscriber handles events
    # that never touch the database.
    #
    # @example Registering at boot
    #   Events::Bus.subscribe(Events::Subscribers::TransientBroadcaster.new)
    class TransientBroadcaster
      include Events::Subscriber

      # Event types that are broadcast without persistence.
      TRANSIENT_TYPES = [Events::BounceBack::TYPE].freeze

      # @param event [Hash] Rails.event notification hash
      def emit(event)
        payload = event[:payload]
        return unless payload.is_a?(Hash)

        event_type = payload[:type]
        return unless TRANSIENT_TYPES.include?(event_type)

        session_id = payload[:session_id]
        return unless session_id

        ActionCable.server.broadcast(
          "session_#{session_id}",
          payload.transform_keys(&:to_s)
        )
      end
    end
  end
end
