class AddInitialCwdToSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :sessions, :initial_cwd, :string
  end
end
