# frozen_string_literal: true

class AddViewModeToSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :sessions, :view_mode, :string, default: "basic", null: false
  end
end
