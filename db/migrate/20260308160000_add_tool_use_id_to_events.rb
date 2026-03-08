# frozen_string_literal: true

class AddToolUseIdToEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :events, :tool_use_id, :string
    add_index :events, :tool_use_id
  end
end
