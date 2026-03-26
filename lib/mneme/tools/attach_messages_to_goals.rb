# frozen_string_literal: true

module Mneme
  module Tools
    # Pins critical messages to active Goals so they survive viewport eviction.
    # Mneme calls this when it sees important messages (user instructions, key
    # decisions, critical corrections) approaching the eviction zone.
    #
    # Messages are pinned via a many-to-many join: one message can be attached
    # to multiple Goals. When all referencing Goals complete, the pin is
    # automatically released (reference-counted cleanup in {Goal#release_orphaned_pins!}).
    class AttachMessagesToGoals < ::Tools::Base
      def self.tool_name = "attach_messages_to_goals"

      def self.description = "Pin critical messages to goals so they survive viewport eviction."

      def self.input_schema
        {
          type: "object",
          properties: {
            message_ids: {
              type: "array",
              items: {type: "integer"}
            },
            goal_ids: {
              type: "array",
              items: {type: "integer"}
            }
          },
          required: %w[message_ids goal_ids]
        }
      end

      # @param main_session [Session] the session being observed
      def initialize(main_session:, **)
        @session = main_session
      end

      # @param input [Hash<String, Object>] with "message_ids" and "goal_ids"
      # @return [String] confirmation with link count, or error description
      def execute(input)
        message_ids = Array(input["message_ids"]).map(&:to_i).uniq
        goal_ids = Array(input["goal_ids"]).map(&:to_i).uniq

        return "Error: message_ids cannot be empty" if message_ids.empty?
        return "Error: goal_ids cannot be empty" if goal_ids.empty?

        messages = @session.messages.where(id: message_ids)
        all_goals = @session.goals
        goals = all_goals.active.where(id: goal_ids)

        missing_messages = message_ids - messages.pluck(:id)
        inactive_goal_ids = goal_ids - goals.pluck(:id)

        errors = []
        errors << "Messages not found: #{missing_messages.join(", ")}" if missing_messages.any?

        if inactive_goal_ids.any?
          completed_ids = all_goals.completed.where(id: inactive_goal_ids).pluck(:id)
          not_found_ids = inactive_goal_ids - completed_ids
          errors << "Goals already completed: #{completed_ids.join(", ")}" if completed_ids.any?
          errors << "Goals not found: #{not_found_ids.join(", ")}" if not_found_ids.any?
        end

        return "Error: #{errors.join("; ")}" if errors.any?

        attached = attach(messages, goals)
        "Pinned #{attached} message-goal links"
      end

      private

      def attach(messages, goals)
        messages.sum do |message|
          pinned = find_or_create_pinned_message(message)
          link_to_goals(pinned, goals)
        end
      end

      def link_to_goals(pinned, goals)
        goals.each { |goal| GoalPinnedMessage.find_or_create_by!(goal: goal, pinned_message: pinned) }
        goals.size
      end

      def find_or_create_pinned_message(message)
        PinnedMessage.find_or_create_by!(message: message) do |pm|
          pm.display_text = truncate_message_content(message)
        end
      end

      def truncate_message_content(message)
        content = message.payload&.dig("content").to_s.strip
        content = "message #{message.id}" if content.empty?

        if content.length > PinnedMessage::MAX_DISPLAY_TEXT_LENGTH
          content[0, PinnedMessage::MAX_DISPLAY_TEXT_LENGTH - 1] + "…"
        else
          content
        end
      end
    end
  end
end
