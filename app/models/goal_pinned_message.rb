# frozen_string_literal: true

# Join record linking a {Goal} to a {PinnedMessage}. Many-to-many: one message
# can be pinned to multiple Goals, and one Goal can reference multiple pins.
# When the last Goal referencing a pin completes, the pin is released.
class GoalPinnedMessage < ApplicationRecord
  belongs_to :goal
  belongs_to :pinned_message

  validates :pinned_message_id, uniqueness: {scope: :goal_id}
end
