# frozen_string_literal: true

module Events
  module Subscribers
    # Routes text messages between parent and child sessions, enabling
    # bidirectional @mention communication.
    #
    # **Child → Parent:** When a sub-agent emits an {Events::AgentMessage},
    # the router persists a {Events::UserMessage} in the parent session
    # with attribution prefix, then wakes the parent via {AgentRequestJob}.
    #
    # **Parent → Child:** When a parent agent emits an {Events::AgentMessage}
    # containing `@name` mentions, the router persists the message in each
    # matching child session and wakes them via {AgentRequestJob}.
    #
    # Both directions use direct persistence + job enqueue (same pattern as
    # {Tools::SpawnSubagent#spawn_child}) to avoid conflicts with the global
    # {Persister} which skips non-pending user messages.
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

      # @param event [Hash] Rails.event notification hash
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

      # Forwards a sub-agent's text message to its parent session.
      # Persists directly and enqueues a job so the parent agent wakes
      # up to process the message.
      #
      # @param child [Session] the sub-agent session
      # @param content [String] the sub-agent's message text
      def route_to_parent(child, content)
        parent = child.parent_session
        return unless parent

        name = child.name || "agent-#{child.id}"
        attributed = format(ATTRIBUTION_FORMAT, name, content)

        parent.create_user_event(attributed)
        AgentRequestJob.perform_later(parent.id)
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

          child.create_user_event(content)
          AgentRequestJob.perform_later(child.id)
        end
      end
    end
  end
end
