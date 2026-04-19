# frozen_string_literal: true

module Events
  # Emitted by the drain loop after a single LLM round-trip completes.
  # Carries the raw Anthropic response so downstream subscribers can
  # persist messages, transition session state, and dispatch tool
  # execution when the response is a +tool_use+.
  #
  # The drain loop hands off via this event — it does not persist
  # Messages or release the session itself. Single responsibility:
  # one subscriber pumps PendingMessages into the LLM, another owns
  # the aftermath.
  class LLMResponded
    TYPE = "session.llm_responded"

    attr_reader :session_id, :response, :api_metrics

    # @param session_id [Integer] session that made the LLM call
    # @param response [Hash] raw Anthropic response (with +content+ and +stop_reason+)
    # @param api_metrics [Hash, nil] rate-limit and usage metrics from the provider
    def initialize(session_id:, response:, api_metrics: nil)
      @session_id = session_id
      @response = response
      @api_metrics = api_metrics
    end

    def event_name
      "#{Bus::NAMESPACE}.#{TYPE}"
    end

    def to_h
      {type: TYPE, session_id:, response:, api_metrics:}
    end
  end
end
