# frozen_string_literal: true

module Mneme
  module Tools
    # Sentinel tool signaling that Mneme has reviewed the viewport and
    # determined no snapshot is needed. Called when the conversation
    # context doesn't contain enough meaningful content to summarize.
    class EverythingOk < ::Tools::Base
      def self.tool_name = "everything_ok"

      def self.description = "Signal that no snapshot is needed. " \
        "Call this when the eviction zone contains only mechanical " \
        "activity (tool calls) with no meaningful conversation to summarize."

      def self.input_schema
        {type: "object", properties: {}, required: []}
      end

      def execute(_input)
        "Acknowledged. No snapshot needed."
      end
    end
  end
end
