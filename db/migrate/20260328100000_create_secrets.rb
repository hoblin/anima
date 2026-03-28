# frozen_string_literal: true

class CreateSecrets < ActiveRecord::Migration[8.1]
  def change
    create_table :secrets do |t|
      t.string :namespace, null: false
      t.string :key, null: false
      t.text :value, null: false

      t.timestamps
    end

    add_index :secrets, [:namespace, :key], unique: true
  end
end
