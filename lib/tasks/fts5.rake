# frozen_string_literal: true

# Strips internal FTS5 tables from structure.sql after schema dump.
# SQLite auto-creates these when the virtual table is loaded — including
# them causes "reserved for internal use" errors on db:schema:load.
Rake::Task["db:schema:dump"].enhance do
  path = Rails.root.join("db/structure.sql")
  next unless path.exist?

  cleaned = path.read.gsub(/^CREATE TABLE IF NOT EXISTS 'events_fts_\w+'.*;\n/, "")
  path.write(cleaned)
end
