# frozen_string_literal: true

# Decorates {PendingMessage} records so Mneme and Melete can render them
# alongside real {Message} rows in their extended-context transcripts
# (brainstorm: "peek into the future" — PMs are what will be in the
# LLM conversation once the drain promotes them).
#
# Not used by the main TUI. Skills/workflows/goals/recall PMs become
# phantom pairs in real Messages on promotion and render there; this
# decorator only covers the pre-promotion view that enrichment
# subsystems consume.
#
# @example
#   pm.decorate.render("melete") #=> "User: please ship the fix"
class PendingMessageDecorator < ApplicationDecorator
  delegate_all

  RENDER_DISPATCH = {
    "melete" => :render_melete,
    "mneme" => :render_mneme
  }.freeze
  private_constant :RENDER_DISPATCH

  # Dispatches to the render method for the given enrichment subsystem.
  #
  # @param mode [String] "melete" or "mneme"
  # @return [String, nil] transcript line, or nil to skip
  # @raise [ArgumentError] if the mode is not supported
  def render(mode)
    method = RENDER_DISPATCH[mode]
    raise ArgumentError, "Invalid view mode: #{mode.inspect}" unless method

    public_send(method)
  end

  # Transcript line for Melete. Includes the raw user prompt (her main
  # signal for skill/workflow choice) and attribution-formatted
  # sub-agent replies, Mneme recalls, and goal events from earlier
  # stages of the pipeline.
  #
  # @return [String] single-line transcript entry
  def render_melete
    case message_type
    when "user_message"
      "User (pending): #{truncate_middle(content)}"
    when "subagent"
      "Sub-agent #{source_name} (pending): #{truncate_middle(content)}"
    when "tool_response"
      "tool_response #{tool_use_id} (pending): #{truncate_middle(content)}"
    when "from_mneme"
      "Mneme recalled (pending): #{truncate_middle(content)}"
    when "from_melete_skill"
      "Melete activated skill: #{source_name}"
    when "from_melete_workflow"
      "Melete activated workflow: #{source_name}"
    when "from_melete_goal"
      "Melete logged goal #{source_name}: #{truncate_middle(content)}"
    end
  end

  # Transcript line for Mneme. User messages and agent-bound tool
  # responses feed her associative recall; enrichment-side PMs
  # (skills/workflows/goals/recall) are noise for the passive-recall
  # query and are skipped.
  #
  # @return [String, nil] transcript line, or nil to skip
  def render_mneme
    case message_type
    when "user_message"
      "User (pending): #{truncate_middle(content)}"
    when "subagent"
      "Sub-agent #{source_name} (pending): #{truncate_middle(content)}"
    when "tool_response"
      "tool_response #{tool_use_id} (pending): #{truncate_middle(content)}"
    end
  end

  private

  MIDDLE_TRUNCATION_MARKER = MessageDecorator::MIDDLE_TRUNCATION_MARKER

  # Mirror of {MessageDecorator#truncate_middle} — duplicated here
  # rather than inherited to keep the two decorator families
  # independent.
  def truncate_middle(text, max_chars: 500)
    str = text.to_s
    return str if str.length <= max_chars

    keep = max_chars - MIDDLE_TRUNCATION_MARKER.length
    head = keep / 2
    tail = keep - head
    "#{str[0, head]}#{MIDDLE_TRUNCATION_MARKER}#{str[-tail, tail]}"
  end
end
