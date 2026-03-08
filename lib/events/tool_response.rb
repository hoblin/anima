# frozen_string_literal: true

module Events
  class ToolResponse < Base
    TYPE = "tool_response"

    attr_reader :tool_name, :success, :tool_use_id

    # @param content [String] tool execution output
    # @param tool_name [String] registered tool name
    # @param success [Boolean] whether the tool executed successfully
    # @param tool_use_id [String, nil] Anthropic-assigned ID for correlating call/result
    # @param session_id [String, nil] optional session identifier
    def initialize(content:, tool_name:, success: true, tool_use_id: nil, session_id: nil)
      super(content: content, session_id: session_id)
      @tool_name = tool_name
      @success = success
      @tool_use_id = tool_use_id
    end

    def type
      TYPE
    end

    def success?
      @success
    end

    def to_h
      super.merge(tool_name: tool_name, success: success, tool_use_id: tool_use_id)
    end
  end
end
