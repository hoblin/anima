# frozen_string_literal: true

module Events
  module Subscribers
    # Routes text messages between parent and child sessions, enabling
    # bidirectional @mention communication.
    #
    # **Child → Parent:** When a sub-agent emits an {Events::AgentMessage},
    # the router creates a {Events::UserMessage} in the parent session
    # with attribution prefix. If the parent is idle, persists directly
    # and wakes it via {AgentRequestJob}. If the parent is mid-turn,
    # emits a pending message that is promoted after the current loop
    # completes — same mechanism as {SessionChannel#speak}.
    #
    # **Parent → Child:** When a parent agent emits an {Events::AgentMessage}
    # containing `@name` mentions, the router persists the message in each
    # matching child session and wakes them via {AgentRequestJob}.
    #
    # Both directions delegate to {Session#enqueue_user_message}, which
    # respects the target session's processing state — persisting directly
    # when idle, deferring via pending queue when mid-turn.
    #
    # This replaces the +return_result+ tool — sub-agents communicate
    # through natural text messages instead of structured tool calls.
    class SubagentMessageRouter
      include Events::Subscriber

      # Attribution prefix format for messages routed from child to parent.
      # @example "[sub-agent @loop-sleuth]: Here's what I found..."
      ATTRIBUTION_FORMAT = "[sub-agent @%s]: %s"

      # Regex to extract @mention names from parent agent messages.
      MENTION_PATTERN = /@(\w[\w-]*)/

      # Routes agent text messages between parent and child sessions.
      #
      # For sub-agent sessions: forwards to parent with attribution prefix.
      # For parent sessions: scans for @mentions and routes to matching children.
      #
      # @param event [Hash] Rails.event notification hash with +:payload+ containing
      #   an +agent_message+ event (type, session_id, content)
      # @return [void]
      def emit(event)
        payload = event[:payload]
        return unless payload.is_a?(Hash)
        return unless payload[:type] == "agent_message"

        session_id = payload[:session_id]
        return unless session_id

        content = payload[:content].to_s
        return if content.empty?

        session = Session.find_by(id: session_id)
        return unless session

        if session.sub_agent?
          route_to_parent(session, content)
        else
          route_mentions_to_children(session, content)
        end
      end

      private

      # Forwards a sub-agent's text message to its parent session
      # via {Session#enqueue_user_message}.
      #
      # @param child [Session] the sub-agent session
      # @param content [String] the sub-agent's message text
      def route_to_parent(child, content)
        parent = child.parent_session
        return unless parent

        name = child.name || "agent-#{child.id}"
        attributed = format(ATTRIBUTION_FORMAT, name, content)

        parent.enqueue_user_message(attributed)
      end

      # Scans a parent agent's message for @mentions and routes the message
      # to each mentioned child session.
      #
      # @param parent [Session] the parent session
      # @param content [String] the parent agent's message text
      def route_mentions_to_children(parent, content)
        mentioned_names = content.scan(MENTION_PATTERN).flatten.uniq
        return if mentioned_names.empty?

        active_children = parent.child_sessions.where.not(name: nil).index_by(&:name)
        return if active_children.empty?

        mentioned_names.each do |name|
          child = active_children[name]
          next unless child

          child.enqueue_user_message(content)
        end
      end
    end
  end
end
