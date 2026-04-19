# frozen_string_literal: true

# First stage of the drain pipeline: runs Mneme's associative recall to
# surface relevant memories as background PendingMessages, then hands off
# to Melete via {Events::StartMelete}.
#
# Triggered by {Events::Subscribers::MnemeKickoff} in response to
# {Events::StartMneme}. Runs the existing synchronous
# {Mneme::PassiveRecall} logic — the event is only the entry/exit
# plumbing.
class MnemeEnrichmentJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  # @param session_id [Integer]
  # @param pending_message_id [Integer, nil] the PM that kicked off the chain
  def perform(session_id, pending_message_id: nil)
    session = Session.find(session_id)

    begin
      Mneme::PassiveRecall.new(session).call
    rescue => error
      Mneme.logger.error("PassiveRecall FAILED session=#{session_id}: #{error.class}: #{error.message}")
    end

    Events::Bus.emit(Events::StartMelete.new(
      session_id: session_id,
      pending_message_id: pending_message_id
    ))
  end
end
