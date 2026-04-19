# frozen_string_literal: true

module Events
  module Subscribers
    # Reacts to {Events::AuthenticationRequired} by surfacing the provider
    # rejection to the operator. Emits a +system_message+ into the
    # conversation (so the failure lives in history) and broadcasts an
    # +authentication_required+ frame on the session's ActionCable stream
    # (so the TUI can prompt for a new token).
    #
    # Follows the same shape as {SessionStateBroadcaster}: jobs emit
    # typed events, broadcasters own the ActionCable side.
    class AuthenticationBroadcaster
      include Events::Subscriber

      # @param event [Hash] Rails.event notification hash
      def emit(event)
        payload = event[:payload]
        session_id = payload[:session_id]
        message = payload[:content]

        Events::Bus.emit(Events::SystemMessage.new(
          content: "Authentication failed: #{message}",
          session_id: session_id
        ))

        ActionCable.server.broadcast(
          "session_#{session_id}",
          {"action" => "authentication_required", "message" => message}
        )
      end
    end
  end
end
