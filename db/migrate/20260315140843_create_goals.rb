# frozen_string_literal: true

class CreateGoals < ActiveRecord::Migration[8.1]
  def change
    create_table :goals do |t|
      t.references :session, null: false, foreign_key: true
      t.references :parent_goal, foreign_key: {to_table: :goals}, null: true
      t.text :description, null: false
      t.string :status, default: "active", null: false
      t.datetime :completed_at

      t.timestamps
    end

    add_index :goals, [:session_id, :status]
  end
end
