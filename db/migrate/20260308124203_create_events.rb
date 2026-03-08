# frozen_string_literal: true

class CreateEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :events do |t|
      t.references :session, null: false, foreign_key: true
      t.string :event_type, null: false
      t.json :payload, null: false, default: {}
      t.integer :position, null: false
      t.integer :timestamp, limit: 8, null: false

      t.timestamps
    end

    add_index :events, [:session_id, :position]
    add_index :events, :event_type
  end
end
