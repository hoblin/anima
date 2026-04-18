# frozen_string_literal: true

module Events
  module Subscribers
    # Broadcasts session state over ActionCable in response to
    # {Events::SessionStateChanged}. Sends +session_state+ to the session
    # stream and, for sub-agents, +child_state+ to the parent stream so the
    # HUD updates without a full children refresh.
    #
    # @example Registering at boot
    #   trigger = ->(event) { event[:name] == "anima.session.state_changed" }
    #   Events::Bus.subscribe(Events::Subscribers::SessionStateBroadcaster.new, &trigger)
    class SessionStateBroadcaster
      include Events::Subscriber

      # @param event [Hash] Rails.event notification hash
      def emit(event)
        payload = event[:payload]
        session_id = payload[:session_id]
        state = payload[:state]

        action_payload = {"action" => "session_state", "state" => state, "session_id" => session_id}
        ActionCable.server.broadcast("session_#{session_id}", action_payload)

        parent_id = Session.where(id: session_id).pick(:parent_session_id)
        return unless parent_id

        parent_payload = action_payload.merge("action" => "child_state", "child_id" => session_id)
        ActionCable.server.broadcast("session_#{parent_id}", parent_payload)
      end
    end
  end
end
