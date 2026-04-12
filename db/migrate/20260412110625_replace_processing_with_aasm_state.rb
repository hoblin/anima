class ReplaceProcessingWithAasmState < ActiveRecord::Migration[8.1]
  def change
    add_column :sessions, :aasm_state, :string, default: "idle", null: false
    remove_column :sessions, :processing, :boolean, default: false, null: false
  end
end
