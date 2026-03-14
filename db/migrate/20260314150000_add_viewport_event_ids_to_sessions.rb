# frozen_string_literal: true

class AddViewportEventIdsToSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :sessions, :viewport_event_ids, :json, default: [], null: false
  end
end
