# frozen_string_literal: true

module Events
  module Subscribers
    # Handles the aftermath of a single LLM round-trip emitted via
    # {Events::LLMResponded}. Persists the assistant's output as Message
    # records, transitions the session state, and — when the response
    # includes a +tool_use+ block — queues {ToolExecutionJob} for each
    # tool.
    #
    # This is where session state moves away from +:awaiting+: either
    # {Session#response_complete!} on a text-only response, or
    # {Session#tool_received!} before dispatching tool work. The drain
    # job itself never transitions state past +:awaiting+ — that is this
    # subscriber's responsibility, per the SOLID rule that event
    # emission is the final act of a piece.
    class LLMResponseHandler
      include Events::Subscriber

      # @param event [Hash] Rails.event notification hash
      def emit(event)
        payload = event[:payload]
        session_id = payload[:session_id]
        return unless session_id

        session = Session.find_by(id: session_id)
        return unless session

        response = payload[:response] || {}
        api_metrics = payload[:api_metrics]

        tool_uses = normalize_tool_uses(response)
        text = extract_text(response)

        persist_agent_message(session, text, api_metrics) if text.present?
        tool_uses.each { |tool_use| persist_tool_call(session, tool_use) }

        if tool_uses.any?
          session.tool_received! if session.may_tool_received?
          dispatch_tool_executions(session, tool_uses)
        elsif session.may_response_complete?
          session.response_complete!
        end
      end

      private

      def content_blocks(response)
        response["content"] || response[:content] || []
      end

      def block_type(block)
        block["type"] || block[:type]
      end

      # Returns tool_use blocks with a guaranteed +id+. Generates a UUID
      # once when the provider omits one so persistence and dispatch see
      # the same id — a missing match breaks tool_use/tool_result
      # pairing in the Anthropic conversation.
      def normalize_tool_uses(response)
        content_blocks(response).filter_map do |block|
          next unless block_type(block) == "tool_use"

          {
            "id" => block["id"] || block[:id] || SecureRandom.uuid,
            "name" => block["name"] || block[:name],
            "input" => block["input"] || block[:input] || {}
          }
        end
      end

      def extract_text(response)
        content_blocks(response)
          .select { |block| block_type(block) == "text" }
          .map { |block| block["text"] || block[:text] }
          .join
      end

      def persist_agent_message(session, text, api_metrics)
        session.messages.create!(
          message_type: "agent_message",
          payload: {"type" => "agent_message", "content" => text, "session_id" => session.id},
          timestamp: now_ns,
          api_metrics: api_metrics
        )
      end

      def persist_tool_call(session, tool_use)
        session.messages.create!(
          message_type: "tool_call",
          tool_use_id: tool_use["id"],
          payload: {
            "type" => "tool_call",
            "tool_name" => tool_use["name"],
            "tool_use_id" => tool_use["id"],
            "tool_input" => tool_use["input"],
            "content" => "Calling #{tool_use["name"]}"
          },
          timestamp: now_ns
        )
      end

      def dispatch_tool_executions(session, tool_uses)
        tool_uses.each do |tool_use|
          ToolExecutionJob.perform_later(
            session.id,
            tool_use_id: tool_use["id"],
            tool_name: tool_use["name"],
            tool_input: tool_use["input"]
          )
        end
      end

      def now_ns
        Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
      end
    end
  end
end
