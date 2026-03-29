# frozen_string_literal: true

# Executes an LLM agent loop as a background job with retry logic
# for transient failures (network errors, rate limits, server errors).
#
# Supports two modes:
#
# **Immediate Persist (message_id provided):** The user message was already
# persisted and broadcast by the caller (e.g. {SessionChannel#speak}).
# The job verifies LLM delivery — if the first API call fails, the
# message is deleted and a {Events::BounceBack} is emitted so clients
# can restore the text to the input field.
#
# **Standard (no message_id):** Processes already-persisted messages (e.g.
# after pending message promotion). Uses ActiveJob retry/discard for
# error handling.
#
# @example Immediate Persist — message already saved by SessionChannel
#   AgentRequestJob.perform_later(session.id, message_id: 42)
#
# @example Standard — pending message processing
#   AgentRequestJob.perform_later(session.id)
class AgentRequestJob < ApplicationJob
  queue_as :default

  # ActionCable action signaling clients to prompt for an API token.
  AUTH_REQUIRED_ACTION = "authentication_required"

  # Standard path only — immediate persist handles its own errors.
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
      {"action" => AUTH_REQUIRED_ACTION, "message" => error.message}
    )
  end

  # @param session_id [Integer] ID of the session to process
  # @param message_id [Integer, nil] ID of a pre-persisted user message (triggers delivery verification)
  def perform(session_id, message_id: nil)
    session = Session.find(session_id)

    # Atomic: only one job processes a session at a time.
    return unless claim_processing(session_id)

    run_analytical_brain_blocking(session)

    agent_loop = AgentLoop.new(session: session)

    if message_id
      deliver_persisted_message(session, message_id, agent_loop)
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

  # Verifies LLM delivery for a pre-persisted user message.
  #
  # The message was already created and broadcast by the caller, so
  # the user sees their message immediately. This method makes the
  # first LLM API call — if it fails, the message is deleted and a
  # {Events::BounceBack} notifies clients to remove the phantom
  # message and restore the text to the input field. For
  # {Providers::Anthropic::AuthenticationError}, an additional
  # +authentication_required+ broadcast prompts the client to show
  # the token entry dialog.
  #
  # Unlike the standard path (which uses +retry_on+ / +discard_on+),
  # all errors here are caught and swallowed after emitting a
  # BounceBack — the job completes normally so ActiveJob does not
  # retry a message the user will re-send manually.
  #
  # After successful delivery, continues the agent loop (tool
  # execution, subsequent API calls).
  #
  # @param session [Session] the conversation session
  # @param message_id [Integer] database ID of the pre-persisted user message
  # @param agent_loop [AgentLoop] agent loop instance (reused for continuation)
  def deliver_persisted_message(session, message_id, agent_loop)
    message = Message.find_by(id: message_id, session_id: session.id)
    # Message may have been deleted between SessionChannel#speak and job
    # execution (e.g. user recalled the message). Exit silently — there
    # is nothing to deliver or bounce back.
    return unless message

    content = message.payload["content"]

    begin
      agent_loop.deliver!
    rescue => error
      message.destroy!
      Events::Bus.emit(Events::BounceBack.new(
        content: content,
        error: error.message,
        session_id: session.id,
        message_id: message_id
      ))
      broadcast_auth_required(session.id, error) if error.is_a?(Providers::Anthropic::AuthenticationError)
      return
    end

    agent_loop.run
  end

  def broadcast_auth_required(session_id, error)
    ActionCable.server.broadcast(
      "session_#{session_id}",
      {"action" => AUTH_REQUIRED_ACTION, "message" => error.message}
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
  # Broadcasts +session_state: llm_generating+ and the state change to
  # the parent session's HUD.
  def claim_processing(session_id)
    claimed = Session.where(id: session_id, processing: false).update_all(processing: true) == 1
    if claimed
      session = Session.find_by(id: session_id)
      session&.broadcast_session_state("llm_generating")
      session&.broadcast_children_update_to_parent
    end
    claimed
  end

  # Clears the processing flag so the session can accept new jobs.
  # Broadcasts +session_state: idle+ to the session stream (replaces
  # the old +processing_stopped+ action) and +children_updated+ to the
  # parent session's HUD.
  def release_processing(session_id)
    Session.where(id: session_id).update_all(processing: false)
    session = Session.find_by(id: session_id)
    session&.broadcast_session_state("idle")
    session&.broadcast_children_update_to_parent
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
