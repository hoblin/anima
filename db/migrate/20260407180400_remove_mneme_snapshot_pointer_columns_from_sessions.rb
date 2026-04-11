class RemoveMnemeSnapshotPointerColumnsFromSessions < ActiveRecord::Migration[8.1]
  def change
    remove_column :sessions, :mneme_snapshot_first_message_id, :integer
    remove_column :sessions, :mneme_snapshot_last_message_id, :integer
  end
end
