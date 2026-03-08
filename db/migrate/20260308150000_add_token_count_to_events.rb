# frozen_string_literal: true

class AddTokenCountToEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :events, :token_count, :integer, default: 0, null: false
  end
end
