# frozen_string_literal: true

module Events
  module Subscribers
    # Checks whether Mneme should run after each persisted message.
    # Subscribes to {Events::MessageCreated} events.
    #
    # @example Registering at boot
    #   Events::Bus.subscribe(Events::Subscribers::MnemeScheduler.new) { |event|
    #     event[:name] == "anima.message.created"
    #   }
    class MnemeScheduler
      include Events::Subscriber

      # @param event [Hash] Rails.event notification hash
      def emit(event)
        event[:payload][:message].session.schedule_mneme!
      end
    end
  end
end
