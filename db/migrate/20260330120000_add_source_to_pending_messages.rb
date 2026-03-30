# frozen_string_literal: true

class AddSourceToPendingMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :pending_messages, :source_type, :string, default: "user", null: false
    add_column :pending_messages, :source_name, :string
  end
end
