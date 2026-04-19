# frozen_string_literal: true

module Events
  module Subscribers
    # Records a tool's outcome as a +tool_response+ PendingMessage on
    # {Events::ToolExecuted}. One ToolExecuted → one PM. The subscriber
    # owns no state transitions: the session stays in +:executing+ until
    # {DrainJob} claims it via the +executing → awaiting+ branch of
    # +start_processing+ (gated by +Session#tool_round_complete?+).
    #
    # The PM's +after_create_commit+ emits {Events::StartProcessing}
    # whenever the AASM guard says drain may now claim — typically when
    # the last sibling tool_response of the round lands.
    class ToolResponseCreator
      include Events::Subscriber

      # @param event [Hash] Rails.event notification hash
      def emit(event)
        payload = event[:payload]
        session = Session.find(payload[:session_id])

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
