class AddDrainFieldsToPendingMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :pending_messages, :tool_use_id, :string
    add_column :pending_messages, :success, :boolean
    add_column :pending_messages, :bounce_back, :boolean, default: false, null: false
  end
end
