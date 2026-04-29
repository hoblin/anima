# frozen_string_literal: true

# Second stage of the drain pipeline: runs Mneme's recall loop so any
# older memory she judges useful lands in the mailbox as background
# {PendingMessage}s, then hands off to the drain loop via
# {Events::StartProcessing}.
#
# Triggered by {Events::Subscribers::MnemeKickoff} in response to
# {Events::StartMneme}, which {MeleteEnrichmentJob} only emits when goals
# changed during the preceding Melete run. Runs the phantom
# {Mneme::RecallRunner} loop — the event is only the entry/exit plumbing.
#
# Mneme recall is *enrichment* — it adds recalled memories as background
# phantom pairs but is never required for the primary pipeline to make
# progress. If recall raises (bad FTS5 input, SQL glitch, …) the handoff
# to the drain loop must still happen, otherwise the session's user
# message is stranded in the mailbox with no retry trigger. Exceptions
# are logged loudly so failures stay visible — they just don't gate the drain.
class MnemeEnrichmentJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  # @param session_id [Integer]
  # @param pending_message_id [Integer, nil] the PM that kicked off the chain
  def perform(session_id, pending_message_id: nil)
    session = Session.find(session_id)

    run_recall(session)

    Events::Bus.emit(Events::StartProcessing.new(
      session_id: session_id,
      pending_message_id: pending_message_id
    ))
  end

  private

  def run_recall(session)
    Mneme::RecallRunner.new(session).call
  rescue => error
    msg = "FAILED (recall) session=#{session.id}: #{error.class}: #{error.message}"
    Rails.logger.error("Mneme #{msg}")
    Mneme.logger.error("#{msg}\n#{error.backtrace&.first(10)&.join("\n")}")
  end
end
