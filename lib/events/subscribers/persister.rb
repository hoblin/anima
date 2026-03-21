# frozen_string_literal: true

module Events
  module Subscribers
    # Persists all events to SQLite as they flow through the event bus.
    # Each event is written as an Event record belonging to the active session.
    #
    # When initialized with a specific session, all events are saved to that
    # session. When initialized without one (global mode), the session is
    # looked up from the event's session_id payload field.
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
      # Skips non-pending user messages — those are persisted by
      # {AgentRequestJob} inside a transaction with LLM delivery
      # (Bounce Back, #236). Also skips event types not in {Event::TYPES}
      # (transient events like {Events::BounceBack}).
      #
      # @param event [Hash] with :payload containing event data
      def emit(event)
        payload = event[:payload]
        return unless payload.is_a?(Hash)

        event_type = payload[:type]
        return if event_type.nil?
        return unless Event::TYPES.include?(event_type)
        return if persisted_by_job?(event_type, payload)

        target_session = @session || Session.find_by(id: payload[:session_id])
        return unless target_session

        @mutex.synchronize do
          target_session.events.create!(
            event_type: event_type,
            payload: payload,
            status: payload[:status],
            tool_use_id: payload[:tool_use_id],
            timestamp: payload[:timestamp] || Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
          )
        end
      end

      def session=(new_session)
        @mutex.synchronize { @session = new_session }
      end

      private

      # Non-pending user messages are persisted by {AgentRequestJob} inside
      # a transaction with LLM delivery. Pending messages are still
      # auto-persisted here because they queue while the session is busy.
      def persisted_by_job?(event_type, payload)
        event_type == "user_message" && payload[:status] != Event::PENDING_STATUS
      end
    end
  end
end
