# frozen_string_literal: true

# Executes an LLM agent loop as a background job with retry logic
# for transient failures (network errors, rate limits, server errors).
#
# Supports two modes:
#
# **Bounce Back (content provided):** Persists the user event and verifies
# LLM delivery inside a single transaction. If the first API call fails,
# the transaction rolls back (event never existed) and a {Events::BounceBack}
# is emitted so clients can restore the text to the input field.
#
# **Standard (no content):** Processes already-persisted events (e.g. after
# pending message promotion). Uses ActiveJob retry/discard for error handling.
#
# @example Bounce Back — event-driven via AgentDispatcher
#   AgentRequestJob.perform_later(session.id, content: "hello")
#
# @example Standard — pending message processing
#   AgentRequestJob.perform_later(session.id)
class AgentRequestJob < ApplicationJob
  queue_as :default

  # Standard path only — bounce back handles its own errors.
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
    Events::Bus.emit(Events::SystemMessage.new(
      content: "Authentication failed: #{error.message}",
      session_id: session_id
    ))
    ActionCable.server.broadcast(
      "session_#{session_id}",
      {"action" => "authentication_required", "message" => error.message}
    )
  end

  # @param session_id [Integer] ID of the session to process
  # @param content [String, nil] user message text (triggers Bounce Back when present)
  def perform(session_id, content: nil)
    session = Session.find(session_id)

    # Atomic: only one job processes a session at a time.
    return unless claim_processing(session_id)

    run_analytical_brain_blocking(session)

    agent_loop = AgentLoop.new(session: session)

    if content
      deliver_with_bounce_back(session, content, agent_loop)
    else
      agent_loop.run
    end

    # Process any pending messages queued while we were busy.
    loop do
      promoted = session.promote_pending_messages!
      break if promoted == 0
      agent_loop.run
    end

    session.schedule_analytical_brain!
  ensure
    release_processing(session_id)
    clear_interrupt(session_id)
    agent_loop&.finalize
  end

  private

  # Persists the user event and verifies LLM delivery atomically.
  #
  # Inside a transaction: creates the event record, broadcasts it for
  # optimistic UI, and makes the first LLM API call. If the call fails,
  # a {Events::BounceBack} is emitted and the exception re-raised to
  # trigger rollback — the event never existed in the database.
  #
  # After commit: continues the agent loop (tool execution, subsequent
  # API calls) outside the transaction so tool events broadcast in
  # real time.
  #
  # @param session [Session] the conversation session
  # @param content [String] user message text
  # @param agent_loop [AgentLoop] agent loop instance (reused after commit)
  def deliver_with_bounce_back(session, content, agent_loop)
    event_id = nil

    ActiveRecord::Base.transaction do
      event = persist_user_event(session, content)
      event_id = event.id
      event.broadcast_now!

      agent_loop.deliver!
    rescue => error
      Events::Bus.emit(Events::BounceBack.new(
        content: content,
        error: error.message,
        session_id: session.id,
        event_id: event_id
      ))
      raise
    end

    # Transaction committed — first call succeeded.
    # Continue processing (tool execution, etc.) outside the transaction.
    agent_loop.run
  rescue => error
    # Bounce already emitted inside the transaction rescue.
    # Also trigger auth popup for authentication errors.
    broadcast_auth_required(session.id, error) if error.is_a?(Providers::Anthropic::AuthenticationError)
  end

  # Creates the user event record directly (not via EventBus+Persister).
  # The Persister skips non-pending user messages because the job owns
  # their persistence lifecycle.
  #
  # @param session [Session]
  # @param content [String]
  # @return [Event] the persisted event record
  def persist_user_event(session, content)
    now = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
    session.events.create!(
      event_type: "user_message",
      payload: {type: "user_message", content: content, session_id: session.id, timestamp: now},
      timestamp: now
    )
  end

  def broadcast_auth_required(session_id, error)
    ActionCable.server.broadcast(
      "session_#{session_id}",
      {"action" => "authentication_required", "message" => error.message}
    )
  end

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

  # Safety-net clearing of the interrupt flag.
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
