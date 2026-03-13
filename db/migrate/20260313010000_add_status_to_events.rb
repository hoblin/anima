# frozen_string_literal: true

class AddStatusToEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :events, :status, :string
    add_index :events, [:session_id, :status], name: "index_events_on_session_id_and_status"
  end
end
