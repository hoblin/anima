# frozen_string_literal: true

# Runs the Mneme memory department — a phantom LLM loop that observes
# the main session and creates summaries of conversation context before
# it evicts from the viewport.
#
# Triggered when the terminal event ({Session#mneme_boundary_event_id})
# leaves the viewport, indicating that meaningful context is about to
# be lost.
#
# After L1 snapshot creation, checks whether enough uncovered L1 snapshots
# have accumulated to trigger Level 2 compression.
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
    check_l2_compression(session)
  rescue => error
    log.error("FAILED session=#{session_id}: #{error.class}: #{error.message}")
    raise
  end

  private

  # Triggers L2 compression when enough uncovered L1 snapshots accumulate.
  # Runs inline (same job) since L2 compression is a small, fast LLM call.
  def check_l2_compression(session)
    uncovered = session.snapshots.for_level(1).not_covered_by_l2.count
    threshold = Anima::Settings.mneme_l2_snapshot_threshold

    if uncovered >= threshold
      log.info("session=#{session.id} — #{uncovered} uncovered L1 snapshots, triggering L2 compression")
      Mneme::L2Runner.new(session).call
    end
  end

  def log = Mneme.logger
end
