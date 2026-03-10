# frozen_string_literal: true

# Registers global EventBus subscribers at boot time.
# Subscribers registered here receive all events regardless of which
# process emitted them (TUI, background job, etc.).
Rails.application.config.after_initialize do
  Events::Bus.subscribe(Events::Subscribers::ActionCableBridge.instance)
end
