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
#    along.
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

  retry_on Providers::Anthropic::TransientError,
    wait: :polynomially_longer, attempts: 5 do |job, error|
    Events::Bus.emit(Events::SystemMessage.new(
      content: "Failed after multiple retries: #{error.message}",
      session_id: job.arguments.first
    ))
  end

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

  discard_on ActiveRecord::RecordNotFound

  # @param session_id [Integer]
  def perform(session_id)
    session = Session.find(session_id)
    return unless session.start_processing!

    drained_count, active_pm = drain_mailbox(session)
    return session.response_complete! if drained_count.zero?

    call_llm_and_emit(session)
  rescue => error
    release_after_failure(session, active_pm, error) if session
    raise error unless active_pm&.bounce_back?
  ensure
    @shell_session&.finalize
  end

  private

  # Promotes every drainable PM in one cycle:
  # 1. All +tool_response+ PMs of the just-completed round (the AASM
  #    guard guarantees they are all present when we get here from
  #    +:executing+; from +:idle+ this set is empty).
  # 2. All background phantom pairs (recalls, skill/workflow/goal
  #    activations) so they sit above the next active message.
  # 3. One active FIFO message — a +user_message+ or a +subagent+
  #    delivery. Tool responses are excluded from this pick because they
  #    are already drained in step 1.
  #
  # @param session [Session]
  # @return [Array(Integer, PendingMessage)] count of promoted PMs +
  #   the active PM that rode along (or +nil+ for no active). The count
  #   distinguishes "promoted nothing — release the claim" from "promoted
  #   something — call the LLM".
  def drain_mailbox(session)
    tool_responses = session.pending_messages.where(message_type: "tool_response").order(:created_at).to_a
    tool_responses.each { |pm| promote_tool_response(pm) }

    flush_backgrounds(session)

    active = session.pending_messages.active.where.not(message_type: "tool_response").order(:created_at).first
    promote_active(active) if active

    drained_count = tool_responses.size + (active ? 1 : 0)
    [drained_count, active]
  end

  def promote_tool_response(pm)
    session = pm.session
    content = pm.content
    tool_use_id = pm.tool_use_id
    session.transaction do
      session.messages.create!(
        message_type: "tool_response",
        tool_use_id: tool_use_id,
        payload: {
          "tool_name" => pm.source_name,
          "tool_use_id" => tool_use_id,
          "content" => content,
          "success" => pm.success
        },
        timestamp: now_ns,
        token_count: TokenEstimation.estimate_token_count(content)
      )
      pm.destroy!
    end
    pm
  end

  def flush_backgrounds(session)
    session.pending_messages.background.find_each do |pm|
      session.transaction do
        session.promote_phantom_pair!(pm)
        pm.destroy!
      end
    end
  end

  def promote_active(pm)
    session = pm.session
    session.transaction do
      case pm.message_type
      when "user_message"
        session.create_user_message(pm.display_content, source_type: pm.source_type, source_name: pm.source_name)
      when "subagent"
        session.promote_phantom_pair!(pm)
      else
        raise "DrainJob cannot promote active PendingMessage #{pm.id} with message_type=#{pm.message_type.inspect}"
      end
      pm.destroy!
    end
    pm
  end

  def call_llm_and_emit(session)
    client = build_client(session)
    registry = build_tool_registry(session)

    messages = session.messages_for_llm
    options = llm_options(session, registry)

    response = client.provider.create_message(
      model: client.model,
      messages: messages,
      max_tokens: client.max_tokens,
      tools: registry.schemas,
      include_metrics: true,
      **options
    )

    api_metrics = response.respond_to?(:api_metrics) ? response.api_metrics : nil

    Events::Bus.emit(Events::LLMResponded.new(
      session_id: session.id,
      response: response_hash(response),
      api_metrics: api_metrics
    ))
  end

  # Release the session and, for bounce-back-flagged user messages,
  # notify the TUI to restore the text. Happy-path release belongs to
  # {Events::Subscribers::LLMResponseHandler} — this method only runs
  # when the drain never reached emit.
  def release_after_failure(session, promoted_pm, error)
    session.response_complete! if session.may_response_complete?

    return unless promoted_pm&.bounce_back?

    last_msg = session.messages.where(message_type: "user_message").order(:id).last
    last_msg&.destroy!

    Events::Bus.emit(Events::BounceBack.new(
      content: promoted_pm.content,
      error: error.message,
      session_id: session.id,
      message_id: last_msg&.id
    ))
  end

  def build_client(session)
    if session.sub_agent?
      LLM::Client.new(model: Anima::Settings.subagent_model)
    else
      LLM::Client.new
    end
  end

  def build_tool_registry(session)
    @shell_session = ShellSession.new(session_id: session.id)
    restore_cwd(@shell_session, session)
    Tools::Registry.build(session: session, shell_session: @shell_session)
  end

  def restore_cwd(shell_session, session)
    cwd = session.initial_cwd
    return unless cwd.present? && File.directory?(cwd)
    shell_session.run("cd #{Shellwords.shellescape(cwd)}")
  end

  def llm_options(session, registry)
    options = {}
    prompt = session.system_prompt
    options[:system] = prompt if prompt
    session.broadcast_debug_context(system: prompt, tools: registry.schemas)
    options
  end

  def response_hash(response)
    # Providers may wrap the response; unwrap so subscribers see a plain Hash.
    response.respond_to?(:to_h) ? response.to_h.stringify_keys : response
  end

  def now_ns
    Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
  end
end
