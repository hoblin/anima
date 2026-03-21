# frozen_string_literal: true

# Stores passive recall results on the session for viewport injection.
# Cached here so the viewport assembly doesn't need to re-run search
# on every LLM call — only refreshed when goals change.
class AddRecalledEventIdsToSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :sessions, :recalled_event_ids, :json, default: [], null: false
  end
end
