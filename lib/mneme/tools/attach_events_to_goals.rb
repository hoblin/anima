# frozen_string_literal: true

module Mneme
  module Tools
    # Pins critical events to active Goals so they survive viewport eviction.
    # Mneme calls this when it sees important events (user instructions, key
    # decisions, critical corrections) approaching the eviction zone.
    #
    # Events are pinned via a many-to-many join: one event can be attached
    # to multiple Goals. When all referencing Goals complete, the pin is
    # automatically released (reference-counted cleanup in {Goal#release_orphaned_pins!}).
    class AttachEventsToGoals < ::Tools::Base
      def self.tool_name = "attach_events_to_goals"

      def self.description = "Pin critical events to active goals so they survive " \
        "viewport eviction. Use this for events that are too important to lose — " \
        "exact user instructions, key decisions, critical corrections. " \
        "Events stay pinned until all attached goals complete."

      def self.input_schema
        {
          type: "object",
          properties: {
            event_ids: {
              type: "array",
              items: {type: "integer"},
              description: "Database IDs of events to pin (from `event N` prefixes in the viewport)"
            },
            goal_ids: {
              type: "array",
              items: {type: "integer"},
              description: "IDs of active goals to attach the events to"
            }
          },
          required: %w[event_ids goal_ids]
        }
      end

      # @param main_session [Session] the session being observed
      def initialize(main_session:, **)
        @session = main_session
      end

      def execute(input)
        event_ids = Array(input["event_ids"]).map(&:to_i).uniq
        goal_ids = Array(input["goal_ids"]).map(&:to_i).uniq

        return "Error: event_ids cannot be empty" if event_ids.empty?
        return "Error: goal_ids cannot be empty" if goal_ids.empty?

        events = @session.events.where(id: event_ids)
        goals = @session.goals.active.where(id: goal_ids)

        missing_events = event_ids - events.map(&:id)
        missing_goals = goal_ids - goals.map(&:id)

        errors = []
        errors << "Events not found: #{missing_events.join(", ")}" if missing_events.any?
        errors << "Active goals not found: #{missing_goals.join(", ")}" if missing_goals.any?
        return "Error: #{errors.join("; ")}" if errors.any?

        attached = attach(events, goals)
        "Pinned #{attached} event-goal links"
      end

      private

      def attach(events, goals)
        events.sum do |event|
          pinned = find_or_create_pinned_event(event)
          link_to_goals(pinned, goals)
        end
      end

      def link_to_goals(pinned, goals)
        goals.each { |goal| GoalPinnedEvent.find_or_create_by!(goal: goal, pinned_event: pinned) }
        goals.size
      end

      def find_or_create_pinned_event(event)
        @session.pinned_events.find_or_create_by!(event: event) do |pe|
          pe.display_text = truncate_event_content(event)
        end
      end

      def truncate_event_content(event)
        content = event.payload["content"].to_s
        if content.length > PinnedEvent::MAX_DISPLAY_TEXT_LENGTH
          content[0, PinnedEvent::MAX_DISPLAY_TEXT_LENGTH - 1] + "…"
        else
          content
        end
      end
    end
  end
end
