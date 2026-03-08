# frozen_string_literal: true

module Events
  class ToolCall < Base
    TYPE = "tool_call"

    attr_reader :tool_name, :tool_input

    def initialize(content:, tool_name:, tool_input: {}, session_id: nil)
      super(content: content, session_id: session_id)
      @tool_name = tool_name
      @tool_input = tool_input
    end

    def type
      TYPE
    end

    def to_h
      super.merge(tool_name: tool_name, tool_input: tool_input)
    end
  end
end
