# frozen_string_literal: true

module Events
  module Subscribers
    # Persists all events to SQLite as they flow through the event bus.
    # Each event is written as a Message record belonging to the active session.
    #
    # When initialized with a specific session, all events are saved to that
    # session. When initialized without one (global mode), the session is
    # looked up from the event's session_id payload field.
    #
    # User messages are NOT persisted here — they are created directly by
    # their callers ({SessionChannel#speak}, {AgentLoop#run}) so the
    # message ID is available for bounce-back cleanup. Pending user
    # messages live in the {PendingMessage} table, outside the event bus.
    #
    # @example Session-scoped
    #   persister = Events::Subscribers::Persister.new(session)
    #   Events::Bus.subscribe(persister)
    #
    # @example Global (persists events for any session)
    #   persister = Events::Subscribers::Persister.new
    #   Events::Bus.subscribe(persister)
    class Persister
      include Events::Subscriber

      attr_reader :session

      def initialize(session = nil)
        @session = session
        @mutex = Mutex.new
      end

      # Receives a Rails.event notification hash and persists it.
      #
      # Skips user messages — those are persisted by their callers
      # ({SessionChannel#speak}, {AgentLoop#run}). Also skips event
      # types not in {Message::TYPES} (transient events like
      # {Events::BounceBack}).
      #
      # @param event [Hash] with :payload containing event data
      def emit(event)
        payload = event[:payload]
        return unless payload.is_a?(Hash)

        event_type = payload[:type]
        return if event_type.nil?
        return unless Message::TYPES.include?(event_type)
        return if event_type == "user_message"

        target_session = @session || Session.find_by(id: payload[:session_id])
        return unless target_session

        @mutex.synchronize do
          target_session.messages.create!(
            message_type: event_type,
            payload: payload,
            tool_use_id: payload[:tool_use_id],
            timestamp: payload[:timestamp] || Time.current.to_ns,
            api_metrics: payload[:api_metrics]
          )
        end
      end

      def session=(new_session)
        @mutex.synchronize { @session = new_session }
      end
    end
  end
end
