# frozen_string_literal: true

class AddNameToSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :sessions, :name, :string
  end
end
