class AddSubagentSupportToSessions < ActiveRecord::Migration[8.1]
  def change
    add_reference :sessions, :parent_session, foreign_key: {to_table: :sessions}, null: true
    add_column :sessions, :prompt, :text
  end
end
