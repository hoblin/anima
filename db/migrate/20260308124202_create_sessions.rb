# frozen_string_literal: true

class CreateSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :sessions do |t|
      t.timestamps
    end
  end
end
