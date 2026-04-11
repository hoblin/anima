class AddTokenCountToPinnedMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :pinned_messages, :token_count, :integer, null: false, default: 0
  end
end
