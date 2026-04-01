# frozen_string_literal: true

class AddApiMetricsToMessages < ActiveRecord::Migration[8.0]
  def change
    add_column :messages, :api_metrics, :json
  end
end
