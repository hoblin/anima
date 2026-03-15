# frozen_string_literal: true

# Executes an LLM agent loop as a background job with retry logic
# for transient failures (network errors, rate limits, server errors).
#
# Emits events via {Events::Bus} as it progresses, making results visible
# to any subscriber (TUI, WebSocket clients). All retry and failure
# notifications are emitted as {Events::SystemMessage} to avoid polluting
# the LLM context window.
#
# @example Inline execution (TUI)
#   AgentRequestJob.perform_now(session.id)
#
# @example Background execution (future Brain/TUI separation)
#   AgentRequestJob.perform_later(session.id)
class AgentRequestJob < ApplicationJob
  queue_as :default

  retry_on Providers::Anthropic::TransientError,
    wait: :polynomially_longer, attempts: 5 do |job, error|
    Events::Bus.emit(Events::SystemMessage.new(
      content: "Failed after multiple retries: #{error.message}",
      session_id: job.arguments.first
    ))
  end

  discard_on ActiveRecord::RecordNotFound
  discard_on Providers::Anthropic::AuthenticationError do |job, error|
    session_id = job.arguments.first
    # Persistent system message for the event log
    Events::Bus.emit(Events::SystemMessage.new(
      content: "Authentication failed: #{error.message}",
      session_id: session_id
    ))
    # Transient signal to trigger TUI token setup popup (not persisted)
    ActionCable.server.broadcast(
      "session_#{session_id}",
      {"action" => "authentication_required", "message" => error.message}
    )
  end

  # @param session_id [Integer] ID of the session to process
  def perform(session_id)
    session = Session.find(session_id)

    # Atomic: only one job processes a session at a time. If another job
    # is already running, this one exits — the running job will pick up
    # any pending messages after its current loop completes.
    return unless claim_processing(session_id)

    # Run analytical brain BEFORE the main agent on user messages so
    # activated skills are available for the current response.
    run_analytical_brain_blocking(session)

    agent_loop = AgentLoop.new(session: session)
    loop do
      agent_loop.run
      promoted = session.promote_pending_messages!
      break if promoted == 0
    end

    # Non-blocking analytical brain run after agent completes —
    # handles post-response updates (renaming, skill changes).
    session.schedule_analytical_brain!
  ensure
    release_processing(session_id)
    agent_loop&.finalize
  end

  private

  # Runs the analytical brain synchronously before the main agent loop.
  # Respects the blocking_on_user_message setting and session guards
  # (skips sub-agents and sessions with too few messages).
  def run_analytical_brain_blocking(session)
    return unless Anima::Settings.analytical_brain_blocking_on_user_message
    return if session.sub_agent?

    AnalyticalBrain::Runner.new(session).call
  rescue => error
    # The analytical brain is best-effort: skill activation enhances the
    # response but the main agent must still reply even if it fails.
    Rails.logger.error("Analytical brain (blocking) failed: #{error.class}: #{error.message}")
    Rails.logger.error(error.backtrace&.first(10)&.join("\n"))
  end

  # Sets the session's processing flag atomically. Returns true if this
  # job claimed the lock, false if another job already holds it.
  def claim_processing(session_id)
    Session.where(id: session_id, processing: false).update_all(processing: true) == 1
  end

  # Clears the processing flag so the session can accept new jobs.
  def release_processing(session_id)
    Session.where(id: session_id).update_all(processing: false)
  end

  # Emits a system message before each retry so the user sees
  # "retrying..." instead of nothing.
  def retry_job(options = {})
    error = options[:error]
    wait = options[:wait]

    Events::Bus.emit(Events::SystemMessage.new(
      content: "#{error.message} — retrying in #{wait.to_i}s...",
      session_id: arguments.first
    ))

    super
  end
end
