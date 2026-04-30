# frozen_string_literal: true

# Drains the PendingMessage mailbox into a single LLM round-trip.
#
# One invocation == one half-step of the event-driven agent loop:
# 1. Claim the session via {Session#start_processing!} (atomic; bails if
#    another drain already holds the session OR the in-flight tool round
#    is incomplete — the AASM guard +tool_round_complete?+ handles both).
# 2. Promote pending work into the conversation — every tool_response PM
#    of the freshly completed round flushes in one transaction so the
#    LLM sees a whole assistant turn paired with a whole user turn;
#    background phantom pairs flush; one active FIFO message rides
#    along. Promotion lives on {PendingMessage#promote!} — the job only
#    decides what to pick and in which order.
# 3. Make one LLM API call and emit {Events::LLMResponded}.
#
# On the happy path the job never releases the session — state
# transitions after the emit belong to
# {Events::Subscribers::LLMResponseHandler} (on text or tool dispatch).
# {Events::Subscribers::ToolResponseCreator} no longer touches state;
# the +executing → awaiting+ branch of +start_processing+ closes the
# tool round and claims in one atomic, lock-protected step.
#
# The job DOES release its own claim when there is no responder to do
# it: an empty mailbox (spurious kickoff) or an exception raised before
# the LLM call succeeded. Those are lifecycle edges of the claim itself,
# not hand-offs to responders.
#
# @see Events::Subscribers::DrainKickoff — enqueues this job
# @see Events::LLMResponded — the event emitted on LLM completion
class DrainJob < ApplicationJob
  queue_as :default

  # Transient provider errors retry inline within {#call_llm_and_emit}.
  # A job-level +retry_on+ would be a no-op here: {PendingMessage#promote!}
  # destroys the PM rows *before* the LLM call, so a retried job would find
  # an empty mailbox and exit without ever re-issuing the request.

  discard_on Providers::Anthropic::AuthenticationError do |job, error|
    Events::Bus.emit(Events::AuthenticationRequired.new(
      session_id: job.arguments.first,
      content: error.message
    ))
  end

  discard_on ActiveRecord::RecordNotFound

  # @param session_id [Integer]
  def perform(session_id)
    @session = Session.find(session_id)
    unless @session.start_processing!
      diagnostics_log.info(
        "session=#{session_id} DrainJob — start_processing! refused: " \
        "state=#{@session.aasm_state} round_complete?=#{@session.tool_round_complete?} " \
        "mailbox_active=#{@session.pending_messages.active.count} " \
        "mailbox_background=#{@session.pending_messages.background.count}"
      )
      return
    end

    drained = drain_mailbox
    return @session.response_complete! if drained.zero?

    call_llm_and_emit
  rescue Providers::Anthropic::AuthenticationError => error
    release_after_failure(error) if @session
    raise
  rescue => error
    release_after_failure(error) if @session
    raise unless @active_pm&.bounce_back?
  end

  private

  # Decides what the upcoming LLM round will carry and promotes those PMs.
  #
  # 1. All +tool_response+ PMs of the just-completed round — the AASM
  #    guard guarantees they are all present when we arrive from
  #    +:executing+; from +:idle+ this set is empty.
  # 2. Pick one active FIFO message (user_message or subagent) to ride
  #    along. If there are no tool_responses AND no active message, the
  #    LLM call is a no-op: release the claim and do NOT flush background
  #    PMs (they stay in the mailbox for the next turn).
  # 3. Flush background phantom pairs so they sit above the active pick.
  # 4. Promote the active pick.
  #
  # @return [Integer] count of PMs promoted this cycle (0 means "release
  #   the claim without calling the LLM")
  def drain_mailbox
    tool_responses = @session.pending_messages.where(message_type: "tool_response").order(:created_at).to_a
    @active_pm = @session.pending_messages.active.where.not(message_type: "tool_response").order(:created_at).first

    promoted = tool_responses.size + (@active_pm ? 1 : 0)

    diagnostics_log.info(
      "session=#{@session.id} drain_mailbox — tool_responses=#{tool_responses.size} " \
      "active_pm=#{@active_pm&.id || "nil"}#{"(#{@active_pm.message_type})" if @active_pm} " \
      "background=#{@session.pending_messages.background.count} promoted=#{promoted}"
    )
    if tool_responses.any?
      diagnostics_log.debug(
        "  tool_response PMs: " +
          tool_responses.map { |pm| "PM##{pm.id}(uid=#{pm.tool_use_id} src=#{pm.source_name})" }.join(", ")
      )
    end

    return 0 if promoted.zero?

    tool_responses.each(&:promote!)
    @session.pending_messages.background.find_each(&:promote!)
    @active_pm&.promote!

    promoted
  end

  def call_llm_and_emit
    prompt = @session.system_prompt
    @session.broadcast_debug_context(system: prompt, tools: registry.schemas)

    response = with_transient_retry do
      client.provider.create_message(
        model: client.model,
        messages: @session.messages_for_llm,
        max_tokens: client.max_tokens,
        tools: registry.schemas,
        include_metrics: true,
        **(prompt ? {system: prompt} : {})
      )
    end

    Events::Bus.emit(Events::LLMResponded.new(
      session_id: @session.id,
      response: response.to_h.stringify_keys,
      api_metrics: response.api_metrics
    ))
  end

  # Retries the LLM call in-place on transient provider errors. The
  # polynomial-backoff formula mirrors ActiveJob's +:polynomially_longer+.
  # On final exhaustion the subscriber-visible SystemMessage is emitted
  # before the error re-raises into {#perform}'s rescue path for release.
  TRANSIENT_RETRY_ATTEMPTS = 5

  def with_transient_retry
    tries = 0
    begin
      yield
    rescue Providers::Anthropic::TransientError => error
      tries += 1
      if tries >= TRANSIENT_RETRY_ATTEMPTS
        Events::Bus.emit(Events::SystemMessage.new(
          content: "Failed after multiple retries: #{error.message}",
          session_id: @session.id
        ))
        raise
      end
      sleep(transient_backoff(tries))
      retry
    end
  end

  def transient_backoff(attempt)
    base = attempt**4
    base + (rand * 0.15 * base)
  end

  def release_after_failure(error)
    if @active_pm&.bounce_back?
      @session.release_with_bounce_back(@active_pm, error)
    elsif @session.may_response_complete?
      @session.response_complete!
    end
  end

  def client
    @client ||= if @session.sub_agent?
      LLM::Client.new(model: Anima::Settings.subagent_model)
    else
      LLM::Client.new
    end
  end

  def registry
    @registry ||= Tools::Registry.build(session: @session, shell_session: shell_session)
  end

  def shell_session
    @shell_session ||= ShellSession.for_session(@session)
  end

  def diagnostics_log = BroadcastDiagnostics.logger
end
