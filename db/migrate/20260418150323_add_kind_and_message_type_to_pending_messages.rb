class AddKindAndMessageTypeToPendingMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :pending_messages, :kind, :string, default: "active", null: false
    add_column :pending_messages, :message_type, :string
  end
end
