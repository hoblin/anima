# frozen_string_literal: true

# First stage of the drain pipeline: runs Melete to activate skills,
# read workflows, and refine goals. Hands off to either Mneme (when goals
# changed during this run) or directly to the drain loop.
#
# Triggered by {Events::Subscribers::MeleteKickoff} in response to
# {Events::StartMelete}. Runs the existing synchronous {Melete::Runner}
# — the event is only the entry/exit plumbing.
#
# A scoped {GoalChangeListener} subscribes to {Events::GoalCreated} and
# {Events::GoalUpdated} for the duration of the runner call. When the
# listener sees a goal mutation, the job emits {Events::StartMneme} so
# Mneme recalls against the fresh goal set. Otherwise the job emits
# {Events::StartProcessing} and Mneme is skipped — there is no new
# search seed to recall against.
#
# Sub-agents skip Melete entirely (sub-agent nickname assignment is a
# one-time step, not part of the recurring pipeline). With no runner
# call, the listener never fires and the job falls through to
# {Events::StartProcessing}.
#
# Exceptions from {Melete::Runner#call} propagate — no defensive rescue.
# A crashed Melete leaves the session idle with the PM still in the
# mailbox; the next PM create (or idle-wake re-route) retries the full
# chain. Swallowing would surface a degraded response to the user without
# the failure being visible anywhere (anti-pattern per the project's
# "soft error paths" principle).
class MeleteEnrichmentJob < ApplicationJob
  # Tiny purpose-built listener: flips a flag the first time it sees a
  # goal mutation event. Lives only for the scope of one perform call so
  # subscribe / unsubscribe stay paired.
  class GoalChangeListener
    def initialize
      @triggered = false
    end

    def emit(_event)
      @triggered = true
    end

    def triggered?
      @triggered
    end
  end

  GOAL_CHANGE_EVENT_NAMES = [
    "#{Events::Bus::NAMESPACE}.#{Events::GoalCreated::TYPE}",
    "#{Events::Bus::NAMESPACE}.#{Events::GoalUpdated::TYPE}"
  ].freeze

  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  # @param session_id [Integer]
  # @param pending_message_id [Integer, nil] the PM that kicked off the chain
  def perform(session_id, pending_message_id: nil)
    session = Session.find(session_id)
    listener = GoalChangeListener.new

    Events::Bus.subscribe(listener) do |event|
      GOAL_CHANGE_EVENT_NAMES.include?(event[:name]) &&
        event[:payload][:session_id] == session_id
    end

    begin
      Melete::Runner.new(session).call unless session.sub_agent?
    ensure
      Events::Bus.unsubscribe(listener)
    end

    next_event_class = listener.triggered? ? Events::StartMneme : Events::StartProcessing
    Events::Bus.emit(next_event_class.new(
      session_id: session_id,
      pending_message_id: pending_message_id
    ))
  end
end
