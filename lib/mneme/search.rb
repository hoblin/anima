# frozen_string_literal: true

module Mneme
  # Full-text search over long-term memory — the message history outside
  # the caller's current viewport. Covers user messages, agent messages,
  # and think messages across every session Anima has ever held.
  #
  # The interface is intentionally abstract — callers receive {Result} structs
  # and never touch FTS5 directly. A future semantic search backend (embeddings,
  # BM25 + re-ranking) can replace the implementation without changing callers.
  #
  # @example Mneme's recall muse searching for the main session
  #   Mneme::Search.query("authentication flow", caller_session: session)
  #
  # @example Aoide searching actively from her own session
  #   Mneme::Search.query("OAuth config", caller_session: session)
  class Search
    # A single search result with enough context for display and drill-down.
    #
    # @!attribute message_id [Integer] the message's database ID
    # @!attribute session_id [Integer] the session owning this message
    # @!attribute snippet [String] highlighted excerpt from the matching content
    # @!attribute rank [Float] FTS5 relevance score (lower = more relevant)
    # @!attribute message_type [String] friendly label: human, anima, system, or thought
    Result = Struct.new(:message_id, :session_id, :snippet, :rank, :message_type, keyword_init: true)

    # Searches long-term memory for the given terms.
    #
    # Excludes messages currently in the caller's viewport so a `LIMIT`-bounded
    # search never burns its slots returning things the caller already has in
    # front of them. A caller with no established Mneme boundary yet (fresh
    # main session, sub-agent) treats the whole session as "in viewport" — none
    # of its own messages surface.
    #
    # @param terms [String] search query (FTS5 syntax: words, phrases, OR/AND/NOT)
    # @param caller_session [Session] the session doing the search — used to
    #   exclude its own viewport from the results. Required; search always
    #   happens from the perspective of a specific session.
    # @param limit [Integer] maximum results
    # @return [Array<Result>] ranked by relevance (best first)
    def self.query(terms, caller_session:, limit: Anima::Settings.recall_max_results)
      new(terms, caller_session: caller_session, limit: limit).call
    end

    def initialize(terms, caller_session:, limit: 5)
      @terms = sanitize_query(terms)
      @caller_session = caller_session
      @limit = limit
      @recency_decay = Anima::Settings.recall_recency_decay
    end

    # @return [Array<Result>] ranked by relevance (best first)
    def call
      return [] if @terms.blank?

      rows = execute_fts_query
      rows.map { |row| build_result(row) }
    end

    private

    # Executes the FTS5 MATCH query with viewport exclusion for the caller.
    #
    # @return [Array<Hash>] raw database rows
    def execute_fts_query
      sql, binds = build_sql_and_binds
      connection.select_all(Arel.sql(sql, *binds), "Mneme::Search").to_a
    end

    # Builds the FTS5 SQL. Viewport exclusion depends on whether the caller's
    # session has a Mneme boundary:
    # * boundary set → exclude caller's messages at or above it (they're visible).
    # * boundary nil → exclude the caller's whole session (no eviction has
    #   happened yet, so everything is visible).
    # Other sessions are always unfiltered — their IDs and boundaries mean
    # nothing to the caller's context.
    def build_sql_and_binds
      binds = [@recency_decay, @terms]

      viewport_clause, viewport_binds = caller_viewport_exclusion
      binds.concat(viewport_binds)
      binds << @limit

      sql = <<~SQL
        SELECT
          m.id AS message_id,
          m.session_id,
          m.message_type,
          CASE
            WHEN m.message_type IN ('user_message', 'agent_message', 'system_message')
              THEN substr(json_extract(m.payload, '$.content'), 1, 300)
            WHEN m.message_type = 'tool_call'
              THEN substr(json_extract(m.payload, '$.tool_input.thoughts'), 1, 300)
          END AS snippet,
          rank / (1.0 + ? * (julianday('now') - julianday(m.created_at)) / 365.0) AS rank
        FROM messages_fts
        JOIN messages m ON m.id = messages_fts.rowid
        WHERE messages_fts MATCH ?
          AND #{viewport_clause}
        ORDER BY rank
        LIMIT ?
      SQL

      [sql, binds]
    end

    # Returns the SQL fragment + bind params that exclude the caller's viewport.
    def caller_viewport_exclusion
      boundary = @caller_session.mneme_boundary_message_id
      if boundary
        ["(m.session_id != ? OR m.id < ?)", [@caller_session.id, boundary]]
      else
        ["m.session_id != ?", [@caller_session.id]]
      end
    end

    FRIENDLY_MESSAGE_TYPES = {
      "user_message" => "human",
      "agent_message" => "anima",
      "system_message" => "system",
      "tool_call" => "thought"
    }.freeze

    # Builds a Result from a raw database row.
    #
    # @param row [Hash]
    # @return [Result]
    def build_result(row)
      raw_type = row["message_type"]
      Result.new(
        message_id: row["message_id"],
        session_id: row["session_id"],
        snippet: row["snippet"],
        rank: row["rank"],
        message_type: FRIENDLY_MESSAGE_TYPES.fetch(raw_type, raw_type)
      )
    end

    # FTS5 logical-operator keywords callers may pass verbatim. Everything
    # else is quote-wrapped, which is SQLite's recommended way to feed
    # untrusted text to +MATCH+ — inside a quoted phrase the tokenizer
    # treats +- : * ^ { } ( )+ and any future operator character as
    # ordinary content, so hazards like +sub-agents+ (parsed as
    # +sub NOT agents+ → +no such column: agents+) and +agents:foo+
    # (parsed as a column filter) become literal phrases.
    #
    # Adding +NEAR+ or any new operator that a caller legitimately needs
    # is a one-line change here; character-level blocklists would need to
    # be re-audited against every FTS5 release.
    #
    # @see https://www.sqlite.org/fts5.html FTS5 query syntax
    # @see https://www.mail-archive.com/sqlite-users@mailinglists.sqlite.org/msg118320.html
    #   Dan Kennedy's canonical guidance on MATCH sanitization
    FTS5_PASSTHROUGH_OPERATORS = Set.new(%w[AND OR NOT NEAR]).freeze
    private_constant :FTS5_PASSTHROUGH_OPERATORS

    # Sanitizes user input for FTS5 MATCH safety by quote-wrapping each
    # token. Logical operators ({FTS5_PASSTHROUGH_OPERATORS}) pass through
    # so callers that intentionally build +word1 OR word2+ queries still
    # get boolean behavior.
    #
    # A query that collapses to operators only (e.g. user typed "and or
    # not") has no operands and would trigger an FTS5 syntax error, so we
    # return an empty string and let {#call} short-circuit via
    # +@terms.blank?+.
    #
    # @param raw [String]
    # @return [String] safe FTS5 query
    def sanitize_query(raw)
      return "" unless raw

      tokens = raw.scan(/"[^"]*"|\S+/).filter_map { |token| sanitize_token(token) }
      return "" if tokens.all? { |t| FTS5_PASSTHROUGH_OPERATORS.include?(t) }

      tokens.join(" ")
    end

    # @param token [String] one whitespace-delimited chunk of user input
    # @return [String, nil] nil when the token is empty after cleanup
    def sanitize_token(token)
      return token if FTS5_PASSTHROUGH_OPERATORS.include?(token)
      return rewrap_phrase(token) if token.start_with?('"')

      quote_as_phrase(token)
    end

    # Rebalances a user-supplied phrase so a stray or doubled quote can't
    # leave the overall query syntactically broken.
    #
    # @param token [String] token starting with +"+
    # @return [String, nil]
    def rewrap_phrase(token)
      inner = token.delete_prefix('"').delete_suffix('"').strip
      inner.empty? ? nil : quote_as_phrase(inner)
    end

    # @param text [String] any token treated as literal content
    # @return [String, nil]
    def quote_as_phrase(text)
      return nil if text.empty?

      %("#{text.gsub('"', '""')}")
    end

    def connection
      ActiveRecord::Base.connection
    end
  end
end
