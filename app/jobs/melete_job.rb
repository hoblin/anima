# frozen_string_literal: true

# Runs Melete — the muse of practice — as a phantom LLM loop that observes
# the main session and performs background maintenance (skill activation,
# session naming, goal tracking).
#
# Scheduling guards live in {Session#schedule_melete!} — this job always
# runs when called.
#
# @example
#   MeleteJob.perform_later(session.id)
class MeleteJob < ApplicationJob
  queue_as :default

  retry_on Providers::Anthropic::TransientError,
    wait: :polynomially_longer, attempts: 3

  discard_on ActiveRecord::RecordNotFound
  discard_on Providers::Anthropic::AuthenticationError

  # @param session_id [Integer] the main Session to analyze
  def perform(session_id)
    session = Session.find(session_id)
    log.info("async job started for session=#{session_id}")
    Melete::Runner.new(session).call
  rescue => error
    log.error("FAILED (async) session=#{session_id}: #{error.class}: #{error.message}")
    raise
  end

  private

  def log = Melete.logger
end
