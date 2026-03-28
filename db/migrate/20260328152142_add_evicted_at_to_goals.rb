class AddEvictedAtToGoals < ActiveRecord::Migration[8.1]
  def change
    add_column :goals, :evicted_at, :datetime
    add_index :goals, :evicted_at
  end
end
