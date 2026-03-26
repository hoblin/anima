# frozen_string_literal: true

# Renames the persistence layer from Event to Message.
#
# Events are ephemeral bus signals; Messages are persisted records of what
# was said, by whom, in which conversation. The Anthropic API calls them
# "messages" — this rename aligns the codebase with the agent's vocabulary.
#
# See: thoughts/shared/notes/2026-03-24/narrative-design-for-agent-prompts.md
class RenameEventToMessage < ActiveRecord::Migration[8.1]
  def up
    # --- FTS5: drop triggers and virtual table (references old table name) ---
    execute "DROP TRIGGER IF EXISTS events_fts_insert"
    execute "DROP TRIGGER IF EXISTS events_fts_delete"
    execute "DROP TABLE IF EXISTS events_fts"

    # --- Main table: events → messages ---
    rename_table :events, :messages
    rename_column :messages, :event_type, :message_type

    # --- Pinned events → pinned messages ---
    rename_table :pinned_events, :pinned_messages
    rename_column :pinned_messages, :event_id, :message_id

    # --- Join table: goal_pinned_events → goal_pinned_messages ---
    rename_table :goal_pinned_events, :goal_pinned_messages
    rename_column :goal_pinned_messages, :pinned_event_id, :pinned_message_id

    # --- Snapshots: event range columns ---
    rename_column :snapshots, :from_event_id, :from_message_id
    rename_column :snapshots, :to_event_id, :to_message_id

    # --- Sessions: event pointer columns ---
    rename_column :sessions, :mneme_boundary_event_id, :mneme_boundary_message_id
    rename_column :sessions, :mneme_snapshot_first_event_id, :mneme_snapshot_first_message_id
    rename_column :sessions, :mneme_snapshot_last_event_id, :mneme_snapshot_last_message_id
    rename_column :sessions, :recalled_event_ids, :recalled_message_ids
    rename_column :sessions, :viewport_event_ids, :viewport_message_ids

    # --- Recreate FTS5 virtual table with new names ---
    execute <<~SQL
      CREATE VIRTUAL TABLE messages_fts USING fts5(
        searchable_text,
        content='',
        contentless_delete=1,
        tokenize='porter unicode61'
      );
    SQL

    execute <<~SQL
      INSERT INTO messages_fts(rowid, searchable_text)
      SELECT m.id,
        CASE
          WHEN m.message_type IN ('user_message', 'agent_message', 'system_message')
            THEN json_extract(m.payload, '$.content')
          WHEN m.message_type = 'tool_call' AND json_extract(m.payload, '$.tool_name') = 'think'
            THEN json_extract(m.payload, '$.tool_input.thoughts')
        END
      FROM messages m
      WHERE (m.message_type IN ('user_message', 'agent_message', 'system_message'))
         OR (m.message_type = 'tool_call' AND json_extract(m.payload, '$.tool_name') = 'think');
    SQL

    execute <<~SQL
      CREATE TRIGGER messages_fts_insert AFTER INSERT ON messages
      WHEN NEW.message_type IN ('user_message', 'agent_message', 'system_message')
        OR (NEW.message_type = 'tool_call' AND json_extract(NEW.payload, '$.tool_name') = 'think')
      BEGIN
        INSERT INTO messages_fts(rowid, searchable_text)
        VALUES (
          NEW.id,
          CASE
            WHEN NEW.message_type IN ('user_message', 'agent_message', 'system_message')
              THEN json_extract(NEW.payload, '$.content')
            WHEN NEW.message_type = 'tool_call'
              THEN json_extract(NEW.payload, '$.tool_input.thoughts')
          END
        );
      END;
    SQL

    execute <<~SQL
      CREATE TRIGGER messages_fts_delete AFTER DELETE ON messages
      WHEN OLD.message_type IN ('user_message', 'agent_message', 'system_message')
        OR (OLD.message_type = 'tool_call' AND json_extract(OLD.payload, '$.tool_name') = 'think')
      BEGIN
        DELETE FROM messages_fts WHERE rowid = OLD.id;
      END;
    SQL
  end

  def down
    # --- FTS5: drop new triggers and table ---
    execute "DROP TRIGGER IF EXISTS messages_fts_insert"
    execute "DROP TRIGGER IF EXISTS messages_fts_delete"
    execute "DROP TABLE IF EXISTS messages_fts"

    # --- Sessions: restore event pointer columns ---
    rename_column :sessions, :mneme_boundary_message_id, :mneme_boundary_event_id
    rename_column :sessions, :mneme_snapshot_first_message_id, :mneme_snapshot_first_event_id
    rename_column :sessions, :mneme_snapshot_last_message_id, :mneme_snapshot_last_event_id
    rename_column :sessions, :recalled_message_ids, :recalled_event_ids
    rename_column :sessions, :viewport_message_ids, :viewport_event_ids

    # --- Snapshots: restore event range columns ---
    rename_column :snapshots, :from_message_id, :from_event_id
    rename_column :snapshots, :to_message_id, :to_event_id

    # --- Join table: goal_pinned_messages → goal_pinned_events ---
    rename_column :goal_pinned_messages, :pinned_message_id, :pinned_event_id
    rename_table :goal_pinned_messages, :goal_pinned_events

    # --- Pinned messages → pinned events ---
    rename_column :pinned_messages, :message_id, :event_id
    rename_table :pinned_messages, :pinned_events

    # --- Main table: messages → events ---
    rename_column :messages, :message_type, :event_type
    rename_table :messages, :events

    # --- Recreate original FTS5 ---
    execute <<~SQL
      CREATE VIRTUAL TABLE events_fts USING fts5(
        searchable_text,
        content='',
        contentless_delete=1,
        tokenize='porter unicode61'
      );
    SQL

    execute <<~SQL
      INSERT INTO events_fts(rowid, searchable_text)
      SELECT e.id,
        CASE
          WHEN e.event_type IN ('user_message', 'agent_message', 'system_message')
            THEN json_extract(e.payload, '$.content')
          WHEN e.event_type = 'tool_call' AND json_extract(e.payload, '$.tool_name') = 'think'
            THEN json_extract(e.payload, '$.tool_input.thoughts')
        END
      FROM events e
      WHERE (e.event_type IN ('user_message', 'agent_message', 'system_message'))
         OR (e.event_type = 'tool_call' AND json_extract(e.payload, '$.tool_name') = 'think');
    SQL

    execute <<~SQL
      CREATE TRIGGER events_fts_insert AFTER INSERT ON events
      WHEN NEW.event_type IN ('user_message', 'agent_message', 'system_message')
        OR (NEW.event_type = 'tool_call' AND json_extract(NEW.payload, '$.tool_name') = 'think')
      BEGIN
        INSERT INTO events_fts(rowid, searchable_text)
        VALUES (
          NEW.id,
          CASE
            WHEN NEW.event_type IN ('user_message', 'agent_message', 'system_message')
              THEN json_extract(NEW.payload, '$.content')
            WHEN NEW.event_type = 'tool_call'
              THEN json_extract(NEW.payload, '$.tool_input.thoughts')
          END
        );
      END;
    SQL

    execute <<~SQL
      CREATE TRIGGER events_fts_delete AFTER DELETE ON events
      WHEN OLD.event_type IN ('user_message', 'agent_message', 'system_message')
        OR (OLD.event_type = 'tool_call' AND json_extract(OLD.payload, '$.tool_name') = 'think')
      BEGIN
        DELETE FROM events_fts WHERE rowid = OLD.id;
      END;
    SQL
  end
end
