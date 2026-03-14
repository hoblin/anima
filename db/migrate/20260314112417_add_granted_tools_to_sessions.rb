class AddGrantedToolsToSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :sessions, :granted_tools, :text
  end
end
