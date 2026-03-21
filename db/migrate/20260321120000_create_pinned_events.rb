# frozen_string_literal: true

# Goal-scoped event pinning: Mneme pins critical events to Goals via a
# many-to-many relationship. Pinned events float above the sliding window,
# protected from viewport eviction. When a Goal completes, events attached
# exclusively to it are automatically released (reference counting).
class CreatePinnedEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :pinned_events do |t|
      t.references :event, null: false, foreign_key: true, index: {unique: true}
      t.text :display_text, null: false

      t.timestamps
    end

    create_table :goal_pinned_events do |t|
      t.references :goal, null: false, foreign_key: true
      t.references :pinned_event, null: false, foreign_key: true

      t.timestamps
    end

    # One event pinned to a goal at most once.
    add_index :goal_pinned_events, [:goal_id, :pinned_event_id], unique: true
  end
end
