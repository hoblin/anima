# frozen_string_literal: true

# Registers global EventBus subscribers at boot time.
# Subscribers registered here receive all events regardless of which
# process emitted them (brain server, background job, etc.).
#
# Two event layers:
# 1. Domain events (anima.agent_message, anima.tool_call, etc.) — raw intent
# 2. Lifecycle events (anima.message.created) — emitted after persistence
#
# Persister bridges layer 1 → 2 by creating Message records whose
# after_create_commit emits MessageCreated events.
MESSAGE_LIFECYCLE_FILTER = ->(event) { event[:name].start_with?("anima.message.") }
MESSAGE_CREATED_FILTER = ->(event) { event[:name] == "anima.message.created" }
EVICTION_FILTER = ->(event) { event[:name] == "anima.eviction.completed" }
ACTIVE_STATE_TRIGGER_FILTER = ->(event) {
  %w[anima.skill.activated anima.workflow.activated anima.eviction.completed].include?(event[:name])
}
SESSION_STATE_FILTER = ->(event) { event[:name] == "anima.session.state_changed" }

Rails.application.config.after_initialize do
  # SessionStateBroadcaster also runs in tests — job/channel specs assert
  # ActionCable broadcasts, which now flow through this subscriber.
  Events::Bus.subscribe(Events::Subscribers::SessionStateBroadcaster.new, &SESSION_STATE_FILTER)

  unless Rails.env.test?
    # --- Domain event subscribers (layer 1) ---

    # Global persister handles events from all sessions (brain server, background jobs).
    # Skips non-pending user messages — those are persisted by their callers
    # (SessionChannel#speak for idle sessions, AgentLoop#process for direct usage).
    Events::Bus.subscribe(Events::Subscribers::Persister.new)

    # Bridges transient events (e.g. BounceBack) to ActionCable for client delivery.
    Events::Bus.subscribe(Events::Subscribers::TransientBroadcaster.new)

    # Routes text messages between parent and sub-agent sessions via @mentions.
    Events::Bus.subscribe(Events::Subscribers::SubagentMessageRouter.new)

    # --- Lifecycle event subscribers (layer 2) ---

    # Broadcasts message creates and updates to connected WebSocket clients.
    Events::Bus.subscribe(Events::Subscribers::MessageBroadcaster.new, &MESSAGE_LIFECYCLE_FILTER)

    # Checks whether Mneme should run after each persisted message.
    Events::Bus.subscribe(Events::Subscribers::MnemeScheduler.new, &MESSAGE_CREATED_FILTER)

    # Broadcasts eviction cutoff to clients after Mneme advances the boundary.
    Events::Bus.subscribe(Events::Subscribers::EvictionBroadcaster.new, &EVICTION_FILTER)

    # Rebroadcasts active skills/workflow on every event that can change
    # the set: skill activation, workflow activation, or eviction.
    Events::Bus.subscribe(Events::Subscribers::ActiveStateBroadcaster.new, &ACTIVE_STATE_TRIGGER_FILTER)
  end
end
