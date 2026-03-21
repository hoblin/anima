# frozen_string_literal: true

# Adds Mneme memory department infrastructure:
# - Terminal event tracking on sessions for viewport eviction detection
# - Snapshot pointers for tracking what Mneme has already summarized
# - Snapshots table for persisted summaries of evicted conversation context
class CreateMnemeSchema < ActiveRecord::Migration[8.1]
  def change
    # Terminal event trigger: the event ID that marks Mneme's boundary.
    # When this event leaves the viewport, Mneme fires.
    add_column :sessions, :mneme_boundary_event_id, :integer

    # Snapshot range pointers: track which events Mneme has summarized.
    add_column :sessions, :mneme_snapshot_first_event_id, :integer
    add_column :sessions, :mneme_snapshot_last_event_id, :integer

    create_table :snapshots do |t|
      t.references :session, null: false, foreign_key: true
      t.text :text, null: false
      t.integer :from_event_id, null: false
      t.integer :to_event_id, null: false
      t.integer :level, null: false, default: 1
      t.integer :token_count, null: false, default: 0

      t.timestamps
    end

    add_index :snapshots, [:session_id, :level]
  end
end
