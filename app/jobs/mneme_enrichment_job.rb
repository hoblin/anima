# frozen_string_literal: true

# First stage of the drain pipeline: runs Mneme's associative recall to
# surface relevant memories as background PendingMessages, then hands off
# to Melete via {Events::StartMelete}.
#
# Triggered by {Events::Subscribers::MnemeKickoff} in response to
# {Events::StartMneme}. Runs the existing synchronous
# {Mneme::PassiveRecall} logic — the event is only the entry/exit
# plumbing.
#
# Mneme recall is *enrichment* — it adds recalled memories as background
# phantom pairs but is never required for the primary pipeline to make
# progress. If recall raises (bad FTS5 input, SQL glitch, …) the handoff
# to Melete must still happen, otherwise the session's user message is
# stranded in the mailbox with no retry trigger. Exceptions are logged
# loudly so failures stay visible — they just don't gate the drain.
class MnemeEnrichmentJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  # @param session_id [Integer]
  # @param pending_message_id [Integer, nil] the PM that kicked off the chain
  def perform(session_id, pending_message_id: nil)
    session = Session.find(session_id)

    run_recall(session)

    Events::Bus.emit(Events::StartMelete.new(
      session_id: session_id,
      pending_message_id: pending_message_id
    ))
  end

  private

  def run_recall(session)
    Mneme::PassiveRecall.new(session).call
  rescue => error
    msg = "FAILED (recall) session=#{session.id}: #{error.class}: #{error.message}"
    Rails.logger.error("Mneme #{msg}")
    Mneme.logger.error("#{msg}\n#{error.backtrace&.first(10)&.join("\n")}")
  end
end
