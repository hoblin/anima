# frozen_string_literal: true

module Events
  module Subscribers
    # Originally forwarded EventBus events to ActionCable. Broadcasting now
    # lives in {Event::Broadcasting} (after_create_commit / after_update_commit),
    # which gives each broadcast a stable Event ID and supports update actions.
    #
    # Kept as a subscriber stub so the initializer registration is harmless;
    # can be removed once all references are cleaned up.
    class ActionCableBridge
      include Events::Subscriber
      include Singleton

      # No-op: broadcasting moved to {Event::Broadcasting} concern.
      def emit(_event) = nil
    end
  end
end
