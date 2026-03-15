# frozen_string_literal: true

class AddActiveSkillsToSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :sessions, :active_skills, :json, default: [], null: false
  end
end
