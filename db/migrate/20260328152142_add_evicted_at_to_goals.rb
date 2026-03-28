class AddEvictedAtToGoals < ActiveRecord::Migration[8.1]
  def change
    add_column :goals, :evicted_at, :datetime
  end
end
