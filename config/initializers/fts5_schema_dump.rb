# frozen_string_literal: true

# Skip FTS5 virtual tables during Ruby schema dump.
# Rails' schema dumper can't express contentless FTS5 tables — the
# migration handles creation. The schema.rb omits the virtual table,
# and db:prepare runs pending migrations to recreate it.
ActiveSupport.on_load(:active_record) do
  require "active_record/connection_adapters/sqlite3/schema_dumper"

  ActiveRecord::ConnectionAdapters::SQLite3::SchemaDumper.prepend(Module.new do
    private

    def virtual_tables(stream)
      # Intentionally empty — FTS5 tables are managed by migrations.
      # The default implementation crashes on contentless FTS5 arguments.
    end
  end)
rescue LoadError
  # Not using SQLite3 adapter — nothing to patch.
  nil
end
