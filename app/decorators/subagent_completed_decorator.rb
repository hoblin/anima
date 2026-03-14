# frozen_string_literal: true

# Decorates subagent_completed events for display in the TUI.
# Visible in all modes — sub-agent results are important conversation content.
class SubagentCompletedDecorator < EventDecorator
  # @return [Hash] structured sub-agent result data
  #   `{role: :subagent, content: String, task: String|nil}`
  def render_basic
    {role: :subagent, content: content, task: payload["task"]}
  end

  # @return [Hash] sub-agent result with timestamp
  def render_verbose
    render_basic.merge(timestamp: timestamp)
  end

  # @return [Hash] full sub-agent result with child session ID and token info
  def render_debug
    render_verbose.merge(child_session_id: payload["child_session_id"]).merge(token_info)
  end
end
