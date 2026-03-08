# frozen_string_literal: true

module Events
  class ToolResponse < Base
    TYPE = "tool_response"

    attr_reader :tool_name, :success

    def initialize(content:, tool_name:, success: true, session_id: nil)
      super(content: content, session_id: session_id)
      @tool_name = tool_name
      @success = success
    end

    def type
      TYPE
    end

    def success?
      @success
    end

    def to_h
      super.merge(tool_name: tool_name, success: success)
    end
  end
end
