# frozen_string_literal: true

module Events
  module Subscribers
    # Closes the tool round. On {Events::ToolExecuted}, creates a
    # +tool_response+ PendingMessage (active) and releases the session
    # from +:executing+ to +:idle+ via {Session#finish!}.
    #
    # The PM's +after_create_commit+ emits {Events::StartProcessing},
    # which wakes the drain loop to pick up the response in the next
    # cycle — completing the tool pair and continuing the LLM
    # conversation.
    class ToolResponseCreator
      include Events::Subscriber

      # @param event [Hash] Rails.event notification hash
      def emit(event)
        payload = event[:payload]
        session_id = payload[:session_id]
        return unless session_id

        session = Session.find_by(id: session_id)
        return unless session

        session.transaction do
          session.finish! if session.may_finish?
          session.pending_messages.create!(
            content: payload[:content].to_s,
            source_type: "tool",
            source_name: payload[:tool_name],
            message_type: "tool_response",
            tool_use_id: payload[:tool_use_id],
            success: payload[:success]
          )
        end
      end
    end
  end
end
