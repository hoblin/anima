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

        BroadcastDiagnostics.logger.info(
          "Message##{message.id} broadcast — type=#{message.message_type} action=#{action} " \
          "tool_use_id=#{message.tool_use_id.inspect} session=#{message.session_id} view_mode=#{session.view_mode}"
        )

        broadcast_payload = message.payload.merge("id" => message.id, "action" => action)
        broadcast_payload["api_metrics"] = message.api_metrics if message.api_metrics.present?
        broadcast_payload["rendered"] = {session.view_mode => message.decorate.render(session.view_mode)}

        ActionCable.server.broadcast("session_#{message.session_id}", broadcast_payload)
      rescue => e
        BroadcastDiagnostics.logger.error(
          "Message##{message&.id} broadcast RAISED — #{e.class}: #{e.message}"
        )
        raise
      end
    end
  end
end
