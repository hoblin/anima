class AddActiveWorkflowToSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :sessions, :active_workflow, :string
  end
end
