# frozen_string_literal: true

module Events
  class ToolCall < Base
    TYPE = "tool_call"

    attr_reader :tool_name, :tool_input, :tool_use_id, :timeout

    # @param content [String] human-readable description of the tool call
    # @param tool_name [String] registered tool name (e.g. "web_get")
    # @param tool_input [Hash] arguments passed to the tool
    # @param tool_use_id [String] Anthropic-assigned ID for correlating call/result
    # @param timeout [Integer] maximum seconds before the call is considered orphaned
    # @param session_id [String, nil] optional session identifier
    def initialize(content:, tool_name:, tool_input: {}, tool_use_id: nil, timeout: nil, session_id: nil)
      super(content: content, session_id: session_id)
      @tool_name = tool_name
      @tool_input = tool_input
      @tool_use_id = tool_use_id
      @timeout = timeout
    end

    def type
      TYPE
    end

    def to_h
      super.merge(tool_name: tool_name, tool_input: tool_input, tool_use_id: tool_use_id, timeout: timeout)
    end
  end
end
