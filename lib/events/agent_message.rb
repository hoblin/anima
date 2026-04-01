# frozen_string_literal: true

module Events
  class AgentMessage < Base
    TYPE = "agent_message"

    attr_reader :api_metrics

    # @param content [String] assistant response text
    # @param session_id [Integer, String] session identifier
    # @param api_metrics [Hash, nil] rate limits and usage from API response
    def initialize(content:, session_id: nil, api_metrics: nil)
      super(content: content, session_id: session_id)
      @api_metrics = api_metrics
    end

    def type
      TYPE
    end

    def to_h
      super.merge(api_metrics: api_metrics)
    end
  end
end
