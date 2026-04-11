# frozen_string_literal: true

module Events
  module Subscribers
    # Broadcasts message lifecycle events to connected WebSocket clients
    # via ActionCable. Subscribes to {Events::MessageCreated} and
    # {Events::MessageUpdated} events.
    #
    # @example Registering at boot
    #   Events::Bus.subscribe(Events::Subscribers::MessageBroadcaster.new) { |event|
    #     event[:name].start_with?("anima.message.")
    #   }
    class MessageBroadcaster
      include Events::Subscriber

      ACTION_MAP = {
        Events::MessageCreated::TYPE => "create",
        Events::MessageUpdated::TYPE => "update"
      }.freeze

      # @param event [Hash] Rails.event notification hash
      def emit(event)
        message = event[:payload][:message]
        action = ACTION_MAP.fetch(event[:payload][:type])
        session = message.session
        decorator = MessageDecorator.for(message)
        broadcast_payload = message.payload.merge("id" => message.id, "action" => action)
        broadcast_payload["api_metrics"] = message.api_metrics if message.api_metrics.present?

        if decorator
          broadcast_payload["rendered"] = {session.view_mode => decorator.render(session.view_mode)}
        end

        ActionCable.server.broadcast("session_#{message.session_id}", broadcast_payload)
      end
    end
  end
end
