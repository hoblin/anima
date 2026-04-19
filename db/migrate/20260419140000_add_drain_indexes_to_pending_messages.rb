class AddDrainIndexesToPendingMessages < ActiveRecord::Migration[8.1]
  def change
    add_index :pending_messages, [:session_id, :message_type, :created_at],
      name: "index_pending_messages_on_drain_ordering"
    add_index :pending_messages, [:session_id, :tool_use_id],
      name: "index_pending_messages_on_session_and_tool_use"
  end
end
