# frozen_string_literal: true

# Runs passive recall after goal updates — searches message history for
# context relevant to active goals and injects phantom tool_call/tool_response
# pairs into the session's message stream.
#
# Phantom pairs ride the conveyor belt like regular messages, getting
# cached, evicted, and compressed by Mneme naturally.
#
# @example
#   PassiveRecallJob.perform_later(session.id)
class PassiveRecallJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  # @param session_id [Integer]
  def perform(session_id)
    session = Session.find(session_id)
    count = Mneme::PassiveRecall.new(session).call

    Mneme.logger.info("session=#{session_id} — passive recall injected #{count} phantom pairs") if count > 0
  end
end
