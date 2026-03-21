# frozen_string_literal: true

# No custom Rake tasks needed — FTS5 virtual tables are handled by:
# - Migration: creates/drops the FTS5 table and triggers
# - Initializer (config/initializers/fts5_schema_dump.rb): skips virtual
#   tables during schema dump since they can't be expressed in Ruby DSL
