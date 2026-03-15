# frozen_string_literal: true

# Runs the analytical brain — a phantom LLM loop that observes the main
# session and performs background maintenance (currently: session naming).
#
# Replaces {GenerateSessionNameJob} with a tool-based architecture that
# future tickets will expand with skill activation, goal tracking, etc.
#
# Scheduling guards live in {Session#schedule_analytical_brain!} — this
# job always runs when called.
#
# @example
#   AnalyticalBrainJob.perform_later(session.id)
class AnalyticalBrainJob < ApplicationJob
  queue_as :default

  retry_on Providers::Anthropic::TransientError,
    wait: :polynomially_longer, attempts: 3

  discard_on ActiveRecord::RecordNotFound
  discard_on Providers::Anthropic::AuthenticationError

  # @param session_id [Integer] the main Session to analyze
  def perform(session_id)
    brain_log = AnalyticalBrain.logger
    session = Session.find(session_id)
    brain_log.info("async job started for session=#{session_id}")
    AnalyticalBrain::Runner.new(session).call
  rescue => error
    brain_log.error("FAILED (async) session=#{session_id}: #{error.class}: #{error.message}")
    raise
  end
end
