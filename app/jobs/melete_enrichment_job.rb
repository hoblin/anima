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
class MeleteEnrichmentJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  # @param session_id [Integer]
  # @param pending_message_id [Integer, nil] the PM that kicked off the chain
  def perform(session_id, pending_message_id: nil)
    session = Session.find(session_id)

    run_melete(session) if Anima::Settings.melete_blocking_on_user_message && !session.sub_agent?

    Events::Bus.emit(Events::StartProcessing.new(
      session_id: session_id,
      pending_message_id: pending_message_id
    ))
  end

  private

  def run_melete(session)
    Melete::Runner.new(session).call
  rescue => error
    msg = "FAILED (enrichment) session=#{session.id}: #{error.class}: #{error.message}"
    Rails.logger.error("Melete #{msg}")
    Melete.logger.error("#{msg}\n#{error.backtrace&.first(10)&.join("\n")}")
  end
end
