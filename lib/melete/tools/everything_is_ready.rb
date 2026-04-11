# frozen_string_literal: true

module Melete
  module Tools
    # Terminal tool that signals the analytical brain has completed its work.
    # Call this when no changes are needed — the current session state is
    # already good.
    #
    # After this tool returns, the LLM responds with text (not another
    # tool call), naturally terminating the chat_with_tools loop.
    class EverythingIsReady < ::Tools::Base
      def self.tool_name = "everything_is_ready"

      def self.description = "Nothing else to do."

      def self.input_schema
        {type: "object", properties: {}, required: []}
      end

      # @param _input [Hash] ignored — this tool takes no input
      # @return [String] confirmation message
      def execute(_input)
        "Acknowledged. No changes needed."
      end
    end
  end
end
