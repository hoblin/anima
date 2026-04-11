# frozen_string_literal: true

module Events
  module Subscribers
    # Broadcasts eviction cutoff to connected WebSocket clients after Mneme
    # advances the boundary. Clients drop all messages above the cutoff
    # (id <= evict_above_id) — older messages at the top of the chat view.
    #
    # @example Registering at boot
    #   Events::Bus.subscribe(Events::Subscribers::EvictionBroadcaster.new) { |event|
    #     event[:name] == "anima.eviction.completed"
    #   }
    class EvictionBroadcaster
      include Events::Subscriber

      # @param event [Hash] Rails.event notification hash
      def emit(event)
        payload = event[:payload]
        ActionCable.server.broadcast(
          "session_#{payload[:session_id]}",
          {"action" => "eviction", "evict_above_id" => payload[:evict_above_id]}
        )
      end
    end
  end
end
