class RemoveRecalledMessageIdsFromSessions < ActiveRecord::Migration[8.1]
  def change
    remove_column :sessions, :recalled_message_ids, :json, default: [], null: false
  end
end
