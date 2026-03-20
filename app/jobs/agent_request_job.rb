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
    bounce_back_user_event(job.arguments.first, error.message)
  end

  discard_on ActiveRecord::RecordNotFound
  discard_on Providers::Anthropic::AuthenticationError do |job, error|
    session_id = job.arguments.first
    bounce_back_user_event(session_id, "Authentication failed: #{error.message}")
    # Transient signal to trigger TUI token setup popup (not persisted)
    ActionCable.server.broadcast(
      "session_#{session_id}",
      {"action" => "authentication_required", "message" => error.message}
    )
  end

  # Removes the last unprocessed user message from the session and broadcasts
  # a bounce_back signal so TUI clients can restore the text to the input field.
  # Called when LLM dispatch fails permanently (authentication) or after all
  # retries are exhausted (transient errors).
  #
  # @param session_id [Integer] session that owns the orphan event
  # @param error_message [String] human-readable error for the flash notification
  def self.bounce_back_user_event(session_id, error_message)
    session = Session.find_by(id: session_id)
    unless session
      Rails.logger.warn("bounce_back: session #{session_id} not found — cannot restore user input")
      return
    end

    last_user_event = session.events
      .where(event_type: "user_message", status: nil)
      .order(id: :desc).first
    unless last_user_event
      Rails.logger.warn("bounce_back: no unprocessed user_message in session #{session_id}")
      return
    end

    content = last_user_event.payload["content"]
    event_id = last_user_event.id
    last_user_event.destroy!

    ActionCable.server.broadcast("session_#{session_id}", {
      "action" => "bounce_back",
      "content" => content,
      "event_id" => event_id,
      "message" => error_message
    })
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
    clear_interrupt(session_id)
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
    msg = "FAILED (blocking) session=#{session.id}: #{error.class}: #{error.message}"
    Rails.logger.error("Analytical brain #{msg}")
    AnalyticalBrain.logger.error("#{msg}\n#{error.backtrace&.first(10)&.join("\n")}")
  end

  # Sets the session's processing flag atomically. Returns true if this
  # job claimed the lock, false if another job already holds it.
  # Broadcasts the state change to the parent session's HUD.
  def claim_processing(session_id)
    claimed = Session.where(id: session_id, processing: false).update_all(processing: true) == 1
    Session.find_by(id: session_id)&.broadcast_children_update_to_parent if claimed
    claimed
  end

  # Clears the processing flag so the session can accept new jobs.
  # Broadcasts the state change to the parent session's HUD.
  def release_processing(session_id)
    Session.where(id: session_id).update_all(processing: false)
    Session.find_by(id: session_id)&.broadcast_children_update_to_parent
  end

  # Safety-net clearing of the interrupt flag. The primary clear happens in
  # {LLM::Client#clear_interrupt!} after handling the interrupt; this ensures
  # the flag is reset even if the job crashes before reaching that code path.
  def clear_interrupt(session_id)
    Session.where(id: session_id, interrupt_requested: true).update_all(interrupt_requested: false)
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
