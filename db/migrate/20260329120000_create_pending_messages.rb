# frozen_string_literal: true

class CreatePendingMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :pending_messages do |t|
      t.references :session, null: false, foreign_key: true
      t.text :content, null: false
      t.timestamps
    end
  end
end
