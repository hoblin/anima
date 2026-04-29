# frozen_string_literal: true

class MeleteEnrichmentJob < ApplicationJob
  # Scoped subscriber that watches the event bus for goal mutation events
  # (+anima.goal.created+, +anima.goal.updated+) belonging to one session,
  # for the duration of a block.
  #
  # Returns +true+ from {.observe} when at least one matching event fired
  # during the block, +false+ otherwise. The subscription is registered
  # before the block runs and removed in an +ensure+ so it is cleaned up
  # even if the block raises.
  #
  # @example
  #   goal_changed = GoalChangeListener.observe(session_id: 42) do
  #     Melete::Runner.new(session).call
  #   end
  class GoalChangeListener
    EVENT_NAMES = [
      "#{Events::Bus::NAMESPACE}.#{Events::GoalCreated::TYPE}",
      "#{Events::Bus::NAMESPACE}.#{Events::GoalUpdated::TYPE}"
    ].freeze

    # @param session_id [Integer] only events whose payload session_id matches count
    # @yield runs while the subscription is active
    # @return [Boolean] whether a matching event fired during the block
    def self.observe(session_id:, &block)
      new(session_id).observe(&block)
    end

    def initialize(session_id)
      @session_id = session_id
      @triggered = false
    end

    def observe
      Events::Bus.subscribe(self) do |event|
        EVENT_NAMES.include?(event[:name]) &&
          event[:payload][:session_id] == @session_id
      end
      yield
      @triggered
    ensure
      Events::Bus.unsubscribe(self)
    end

    # Bus subscriber contract — flips the latch on any matching event.
    # @api private
    def emit(_event)
      @triggered = true
    end
  end
end
