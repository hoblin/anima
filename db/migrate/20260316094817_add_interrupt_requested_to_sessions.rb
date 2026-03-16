class AddInterruptRequestedToSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :sessions, :interrupt_requested, :boolean, default: false, null: false
  end
end
