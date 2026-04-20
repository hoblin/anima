# frozen_string_literal: true

# Runs Mneme's recall loop after goal updates — Mneme decides whether
# older memory would help Aoide now and surfaces what does as
# {PendingMessage}s. Promoted phantom pairs ride the viewport like any
# other messages.
#
# @example
#   PassiveRecallJob.perform_later(session.id)
class PassiveRecallJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  # @param session_id [Integer]
  def perform(session_id)
    session = Session.find(session_id)
    Mneme::RecallRunner.new(session).call
  end
end
