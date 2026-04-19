# frozen_string_literal: true

# Second stage of the drain pipeline: runs Melete to activate skills,
# evaluate goals, and prepare the session, then hands off to the drain
# loop via {Events::StartProcessing}.
#
# Triggered by {Events::Subscribers::MeleteKickoff} in response to
# {Events::StartMelete}. Runs the existing synchronous {Melete::Runner}
# — the event is only the entry/exit plumbing.
#
# Sub-agents skip Melete entirely (sub-agent nickname assignment is a
# one-time step, not part of the recurring pipeline).
#
# Exceptions from {Melete::Runner#call} propagate — no defensive rescue.
# A crashed Melete leaves the session idle with the PM still in the
# mailbox; the next PM create (or idle-wake re-route) retries the full
# chain. Swallowing would surface a degraded response to the user without
# the failure being visible anywhere (anti-pattern per the project's
# "soft error paths" principle).
class MeleteEnrichmentJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  # @param session_id [Integer]
  # @param pending_message_id [Integer, nil] the PM that kicked off the chain
  def perform(session_id, pending_message_id: nil)
    session = Session.find(session_id)

    Melete::Runner.new(session).call unless session.sub_agent?

    Events::Bus.emit(Events::StartProcessing.new(
      session_id: session_id,
      pending_message_id: pending_message_id
    ))
  end
end
