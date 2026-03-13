# frozen_string_literal: true

# Registers global EventBus subscribers at boot time.
# Subscribers registered here receive all events regardless of which
# process emitted them (brain server, background job, etc.).
Rails.application.config.after_initialize do
  # Global persister handles events from all sessions (brain server, background jobs).
  # Skipped in test — specs manage their own persisters for isolation.
  Events::Bus.subscribe(Events::Subscribers::Persister.new) unless Rails.env.test?
end
