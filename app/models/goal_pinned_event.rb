# frozen_string_literal: true

# Join record linking a {Goal} to a {PinnedEvent}. Many-to-many: one event
# can be pinned to multiple Goals, and one Goal can reference multiple pins.
# When the last Goal referencing a pin completes, the pin is released.
class GoalPinnedEvent < ApplicationRecord
  belongs_to :goal
  belongs_to :pinned_event

  validates :pinned_event_id, uniqueness: {scope: :goal_id}
end
