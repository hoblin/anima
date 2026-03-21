# frozen_string_literal: true

# Registers global EventBus subscribers at boot time.
# Subscribers registered here receive all events regardless of which
# process emitted them (brain server, background job, etc.).
Rails.application.config.after_initialize do
  unless Rails.env.test?
    # Global persister handles events from all sessions (brain server, background jobs).
    # Skips non-pending user messages — those are persisted by AgentRequestJob.
    Events::Bus.subscribe(Events::Subscribers::Persister.new)

    # Schedules AgentRequestJob when a non-pending user message is emitted.
    Events::Bus.subscribe(Events::Subscribers::AgentDispatcher.new)

    # Bridges transient events (e.g. BounceBack) to ActionCable for client delivery.
    Events::Bus.subscribe(Events::Subscribers::TransientBroadcaster.new)
  end
end
