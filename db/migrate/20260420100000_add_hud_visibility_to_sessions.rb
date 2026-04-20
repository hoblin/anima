# frozen_string_literal: true

# Sub-agent sessions track presence in the parent's HUD panel through the
# +hud_visible+ boolean. Mneme flips it to +false+ when viewport eviction
# removes every trace of the sub-agent (spawn pair + response pairs). The
# +spawn_tool_use_id+ column lets the trace query find the spawn pair
# directly instead of string-matching the +spawn_subagent+ tool_input.
class AddHudVisibilityToSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :sessions, :hud_visible, :boolean, default: true, null: false
    add_column :sessions, :spawn_tool_use_id, :string

    add_index :sessions, [:parent_session_id, :hud_visible]
  end
end
