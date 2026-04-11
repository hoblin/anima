class RemoveActiveSkillsAndWorkflowFromSessions < ActiveRecord::Migration[8.1]
  def change
    remove_column :sessions, :active_skills, :json
    remove_column :sessions, :active_workflow, :string
  end
end
