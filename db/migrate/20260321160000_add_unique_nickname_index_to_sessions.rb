# frozen_string_literal: true

# Prevents TOCTOU race conditions in sibling nickname assignment.
# Two concurrent spawns under the same parent can no longer both claim
# the same name — the database enforces uniqueness.
class AddUniqueNicknameIndexToSessions < ActiveRecord::Migration[8.0]
  def change
    add_index :sessions, [:parent_session_id, :name],
      unique: true,
      where: "name IS NOT NULL",
      name: "index_sessions_on_parent_and_name_unique"
  end
end
