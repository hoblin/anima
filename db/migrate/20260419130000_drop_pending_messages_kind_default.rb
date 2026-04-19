class DropPendingMessagesKindDefault < ActiveRecord::Migration[8.1]
  def change
    change_column_default :pending_messages, :kind, from: "active", to: nil
  end
end
