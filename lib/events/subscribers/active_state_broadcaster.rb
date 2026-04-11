# frozen_string_literal: true

module Events
  module Subscribers
    # Rebroadcasts the session's active skills and workflow whenever the
    # set can change: skill activation, workflow activation, or Mneme
    # eviction. Same handler, three triggers — each event carries a
    # +session_id+ and the broadcaster reads live state off the session.
    #
    # @example Registering at boot
    #   trigger = ->(event) {
    #     %w[anima.skill.activated anima.workflow.activated anima.eviction.completed]
    #       .include?(event[:name])
    #   }
    #   Events::Bus.subscribe(Events::Subscribers::ActiveStateBroadcaster.new, &trigger)
    class ActiveStateBroadcaster
      include Events::Subscriber

      # @param event [Hash] Rails.event notification hash
      def emit(event)
        session_id = event.dig(:payload, :session_id)
        session = Session.find_by(id: session_id)
        session&.broadcast_active_state!
      end
    end
  end
end
