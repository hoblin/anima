# frozen_string_literal: true

# Creates an FTS5 virtual table for full-text search over event content.
# Indexes user messages, agent messages, and think events across all sessions.
#
# FTS5 is SQLite's built-in full-text search extension — zero external
# dependencies, fast keyword matching. The interface is abstracted behind
# Mneme::Search so a future semantic search backend can swap in without
# changing callers.
#
# Content is stored only in the events table (contentless FTS via content="").
# The FTS index is kept in sync by triggers on INSERT and DELETE.
class CreateEventsFtsIndex < ActiveRecord::Migration[8.1]
  def up
    # FTS5 virtual table — contentless (content="" means no duplicate storage).
    # Columns: event_id (for joins), session_id (for scoping), searchable_text.
    execute <<~SQL
      CREATE VIRTUAL TABLE events_fts USING fts5(
        searchable_text,
        content='',
        contentless_delete=1,
        tokenize='porter unicode61'
      );
    SQL

    # Populate from existing events: user/agent messages + think tool_calls.
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

    # Auto-index new searchable events on INSERT.
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

    # Remove from FTS index when events are deleted.
    # contentless_delete=1 tables use DELETE FROM, not the insert-based delete command.
    execute <<~SQL
      CREATE TRIGGER events_fts_delete AFTER DELETE ON events
      WHEN OLD.event_type IN ('user_message', 'agent_message', 'system_message')
        OR (OLD.event_type = 'tool_call' AND json_extract(OLD.payload, '$.tool_name') = 'think')
      BEGIN
        DELETE FROM events_fts WHERE rowid = OLD.id;
      END;
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS events_fts_insert"
    execute "DROP TRIGGER IF EXISTS events_fts_delete"
    execute "DROP TABLE IF EXISTS events_fts"
  end
end
