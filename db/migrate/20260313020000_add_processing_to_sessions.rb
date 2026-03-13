# frozen_string_literal: true

class AddProcessingToSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :sessions, :processing, :boolean, default: false, null: false
  end
end
