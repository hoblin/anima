# frozen_string_literal: true

module AnalyticalBrain
  module Tools
    # Shared helper for goal tools that enqueue phantom pair messages
    # when the analytical brain creates, updates, or completes a goal.
    #
    # Including classes must set +@main_session+ to the owning {Session}.
    module GoalMessaging
      private

      # Enqueues a goal event as a {PendingMessage} on the main session.
      # Promoted to a phantom tool_use/tool_result pair so the main agent
      # sees "I recalled this goal event" in its conversation history.
      #
      # @param goal [Goal] the goal that changed
      # @param confirmation [String] human-readable event description
      # @return [PendingMessage]
      def enqueue_goal_message(goal, confirmation)
        @main_session.pending_messages.create!(
          content: confirmation,
          source_type: "goal",
          source_name: goal.id.to_s
        )
      end
    end
  end
end
