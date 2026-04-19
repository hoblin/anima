# frozen_string_literal: true

# Drains the PendingMessage mailbox into a single LLM round-trip.
#
# One invocation == one half-step of the event-driven agent loop:
# 1. Claim the session via {Session#start_processing!} (atomic; bails if
#    another drain already holds the session).
# 2. Promote pending work into the conversation — tool responses take
#    priority; otherwise background messages flush and one active
#    message gets promoted.
# 3. Make one LLM API call and emit {Events::LLMResponded}.
#
# The job never releases the session. State transitions after the emit
# belong to {Events::Subscribers::LLMResponseHandler} (on text or tool
# dispatch) and {Events::Subscribers::ToolResponseCreator} (after tool
# execution). Each piece reports completion via an event — event
# emission is the final act that hands control to the next piece.
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

    begin
      promoted_pm = promote_next(session)
      return unless promoted_pm

      call_llm_and_emit(session)
    rescue => error
      bounce_back_or_reraise(session, promoted_pm, error)
    end
  ensure
    release_from_awaiting(session) if session
    @shell_session&.finalize
  end

  private

  # Picks the next unit of work and writes it into +messages+.
  # Tool responses jump the queue; everything else flushes backgrounds
  # and takes one active FIFO.
  #
  # @param session [Session]
  # @return [PendingMessage, nil] the active PM that was promoted (nil when
  #   mailbox held only backgrounds or was entirely empty)
  def promote_next(session)
    actives = session.pending_messages.active
    tool_response = actives.where(message_type: "tool_response").first
    return promote_tool_response(tool_response) if tool_response

    flush_backgrounds(session)
    active = actives.order(:created_at).first
    promote_active(active) if active
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

  # Bounce-back on the user's optimistically-committed message: delete
  # the just-promoted Message so the TUI removes the phantom, emit
  # {Events::BounceBack} so the client restores the text to the input.
  # Non-bounce-back failures propagate to ActiveJob's retry machinery.
  def bounce_back_or_reraise(session, promoted_pm, error)
    raise error unless promoted_pm&.bounce_back?

    last_msg = session.messages.where(message_type: "user_message").order(:id).last
    last_msg&.destroy!

    Events::Bus.emit(Events::BounceBack.new(
      content: promoted_pm.content,
      error: error.message,
      session_id: session.id,
      message_id: last_msg&.id
    ))
  end

  # Ensures the session never sticks in +:awaiting+ — any path through
  # {#perform} that exits while still awaiting an LLM response (success
  # without tool_use lands in {Events::Subscribers::LLMResponseHandler},
  # but our +ensure+ runs before that subscriber if we raised early)
  # releases the claim so future kickoffs can pick up.
  def release_from_awaiting(session)
    session.response_complete! if session.may_response_complete?
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
