# frozen_string_literal: true

module Events
  # Emitted by {ToolExecutionJob} after a tool finishes running.
  # Carries the tool result so the response subscriber can create a
  # +tool_response+ PendingMessage and release the session back to idle
  # — which in turn wakes the drain loop for the next LLM round.
  class ToolExecuted
    TYPE = "session.tool_executed"

    attr_reader :session_id, :tool_use_id, :tool_name, :content, :success

    # @param session_id [Integer] session the tool ran on behalf of
    # @param tool_use_id [String] pairing ID for the originating +tool_use+ block
    # @param tool_name [String] name of the tool that executed
    # @param content [String] tool output (already formatted and truncated)
    # @param success [Boolean] +true+ on normal completion, +false+ on error or interrupt
    def initialize(session_id:, tool_use_id:, tool_name:, content:, success:)
      @session_id = session_id
      @tool_use_id = tool_use_id
      @tool_name = tool_name
      @content = content
      @success = success
    end

    def event_name
      "#{Bus::NAMESPACE}.#{TYPE}"
    end

    def to_h
      {type: TYPE, session_id:, tool_use_id:, tool_name:, content:, success:}
    end
  end
end
