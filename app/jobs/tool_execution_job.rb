# frozen_string_literal: true

# Runs a single tool on behalf of the session and reports the outcome.
#
# Queued by {Events::Subscribers::LLMResponseHandler} when the LLM
# returns a +tool_use+ block. The session is already in the +:executing+
# state (transition owned by the response handler). This job:
#
# 1. Dispatches the tool via {Tools::Registry}.
# 2. Truncates and formats the result.
# 3. Emits {Events::ToolExecuted}.
#
# The job does not release the session or create the +tool_response+
# PendingMessage — that's {Events::Subscribers::ToolResponseCreator}'s
# job. Event emission is the final act that hands control off.
class ToolExecutionJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  # @param session_id [Integer]
  # @param tool_use_id [String] Anthropic-assigned pairing ID
  # @param tool_name [String]
  # @param tool_input [Hash]
  def perform(session_id, tool_use_id:, tool_name:, tool_input:)
    session = Session.find(session_id)
    # ShellSession.for_session returns the conversation's persistent shell
    # — spawned on first use, reused on every subsequent tool call so the
    # agent's cd's and exported env vars survive between calls. We do NOT
    # finalize it here; the shell's lifetime is the Session's lifetime.
    shell_session = ShellSession.for_session(session)
    registry = Tools::Registry.build(session: session, shell_session: shell_session)

    content, success = execute(registry, tool_name, tool_input, tool_use_id)

    Events::Bus.emit(Events::ToolExecuted.new(
      session_id: session_id,
      tool_use_id: tool_use_id,
      tool_name: tool_name,
      content: content,
      success: success
    ))
  rescue => error
    # A missing {Events::ToolExecuted} would leave the session in +:executing+
    # forever. Always emit a synthetic failure event so
    # {Events::Subscribers::ToolResponseCreator} runs and releases the claim.
    Rails.logger.error("ToolExecutionJob crashed: #{error.class}: #{error.message}")
    Events::Bus.emit(Events::ToolExecuted.new(
      session_id: session_id,
      tool_use_id: tool_use_id,
      tool_name: tool_name,
      content: "#{error.class}: #{error.message}",
      success: false
    ))
  end

  private

  # Always emits something executable back — a missing +tool_result+
  # permanently corrupts the Anthropic conversation history.
  def execute(registry, tool_name, tool_input, tool_use_id)
    result = registry.execute(tool_name, tool_input, tool_use_id: tool_use_id)
    result = ::ToolDecorator.call(tool_name, result)
    content = format_result(result)
    content = truncate(content, registry, tool_name)
    [content, !result.is_a?(Hash) || !result.key?(:error)]
  rescue => error
    Rails.logger.error("Tool #{tool_name} raised #{error.class}: #{error.message}")
    [format_result(error: "#{error.class}: #{error.message}"), false]
  end

  def format_result(result)
    result.is_a?(Hash) ? result.to_json : result.to_s
  end

  def truncate(content, registry, tool_name)
    threshold = registry.truncation_threshold(tool_name)
    return content unless threshold

    lines = ::Tools::ResponseTruncator::HEAD_LINES
    ::Tools::ResponseTruncator.truncate(
      content,
      threshold: threshold,
      reason: "#{tool_name} output displays first/last #{lines} lines"
    )
  end
end
