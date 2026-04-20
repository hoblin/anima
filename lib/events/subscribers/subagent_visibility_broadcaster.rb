# frozen_string_literal: true

module Events
  module Subscribers
    # Broadcasts sub-agent eviction to the parent session's stream so the
    # TUI HUD panel removes the entry. Fires in response to
    # {Events::SubagentEvicted}, which {Mneme::Runner} emits after a
    # boundary advance leaves a sub-agent with no remaining traces in the
    # parent viewport.
    #
    # @example Registering at boot
    #   Events::Bus.subscribe(Events::Subscribers::SubagentVisibilityBroadcaster.new) { |event|
    #     event[:name] == "anima.subagent.evicted"
    #   }
    class SubagentVisibilityBroadcaster
      include Events::Subscriber

      # @param event [Hash] Rails.event notification hash
      def emit(event)
        payload = event[:payload]
        session_id = payload[:session_id]
        ActionCable.server.broadcast(
          "session_#{session_id}",
          {
            "action" => "subagent_evicted",
            "session_id" => session_id,
            "child_id" => payload[:child_id]
          }
        )
      end
    end
  end
end
