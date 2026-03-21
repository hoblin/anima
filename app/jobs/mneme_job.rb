# frozen_string_literal: true

# Runs the Mneme memory department — a phantom LLM loop that observes
# the main session and creates summaries of conversation context before
# it evicts from the viewport.
#
# Triggered when the terminal event ({Session#mneme_boundary_event_id})
# leaves the viewport, indicating that meaningful context is about to
# be lost.
#
# @example
#   MnemeJob.perform_later(session.id)
class MnemeJob < ApplicationJob
  queue_as :default

  retry_on Providers::Anthropic::TransientError,
    wait: :polynomially_longer, attempts: 3

  discard_on ActiveRecord::RecordNotFound
  discard_on Providers::Anthropic::AuthenticationError

  # @param session_id [Integer] the main Session to summarize
  def perform(session_id)
    session = Session.find(session_id)
    log.info("job started for session=#{session_id}")
    Mneme::Runner.new(session).call
  rescue => error
    log.error("FAILED session=#{session_id}: #{error.class}: #{error.message}")
    raise
  end

  private

  def log = Mneme.logger
end
