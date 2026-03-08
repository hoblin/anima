# frozen_string_literal: true

class AddEventIndexes < ActiveRecord::Migration[8.1]
  def change
    remove_index :events, [:session_id, :position]
    add_index :events, [:session_id, :position], unique: true
    add_index :events, [:session_id, :event_type]
  end
end
