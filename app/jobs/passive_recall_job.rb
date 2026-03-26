# frozen_string_literal: true

# Runs passive recall after goal updates — searches message history for
# context relevant to active goals and caches results on the session
# for viewport injection.
#
# Idempotent: multiple enqueues for the same session safely overwrite
# each other's results — last one wins.
#
# @example
#   PassiveRecallJob.perform_later(session.id)
class PassiveRecallJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  # @param session_id [Integer]
  def perform(session_id)
    session = Session.find(session_id)
    results = Mneme::PassiveRecall.new(session).call

    if results.any?
      session.update_column(:recalled_message_ids, results.map(&:message_id))
      Mneme.logger.info("session=#{session_id} — passive recall found #{results.size} memories")
    elsif session.recalled_message_ids.present?
      session.update_column(:recalled_message_ids, [])
    end
  end
end
