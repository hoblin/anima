# frozen_string_literal: true

class RemovePositionFromEvents < ActiveRecord::Migration[8.1]
  def change
    remove_index :events, [:session_id, :position]
    remove_column :events, :position, :integer, null: false
  end
end
