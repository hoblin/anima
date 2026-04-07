class RemoveViewportMessageIdsFromSessions < ActiveRecord::Migration[8.1]
  def change
    remove_column :sessions, :viewport_message_ids, :json, default: "[]", null: false
  end
end
