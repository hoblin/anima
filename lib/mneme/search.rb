# frozen_string_literal: true

module Mneme
  # Full-text search over event history using SQLite FTS5.
  # Covers user messages, agent messages, and think events across all sessions.
  #
  # The interface is intentionally abstract — callers receive {Result} structs
  # and never touch FTS5 directly. A future semantic search backend (embeddings,
  # BM25 + re-ranking) can replace the implementation without changing callers.
  #
  # @example Search across all sessions
  #   results = Mneme::Search.query("authentication flow")
  #   results.each { |r| puts "event #{r.event_id}: #{r.snippet}" }
  #
  # @example Search within a single session
  #   results = Mneme::Search.query("OAuth config", session_id: 42)
  class Search
    # A single search result with enough context for display and drill-down.
    #
    # @!attribute event_id [Integer] the event's database ID
    # @!attribute session_id [Integer] the session owning this event
    # @!attribute snippet [String] highlighted excerpt from the matching content
    # @!attribute rank [Float] FTS5 relevance score (lower = more relevant)
    # @!attribute event_type [String] friendly label: human, anima, system, or thought
    Result = Struct.new(:event_id, :session_id, :snippet, :rank, :event_type, keyword_init: true)

    # Searches event history for the given terms.
    #
    # @param terms [String] search query (FTS5 syntax: words, phrases, OR/AND/NOT)
    # @param session_id [Integer, nil] scope to a specific session (nil = all sessions)
    # @param limit [Integer] maximum results
    # @return [Array<Result>] ranked by relevance (best first)
    def self.query(terms, session_id: nil, limit: Anima::Settings.recall_max_results)
      new(terms, session_id: session_id, limit: limit).call
    end

    def initialize(terms, session_id: nil, limit: 5)
      @terms = sanitize_query(terms)
      @session_id = session_id
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

    # Executes the FTS5 MATCH query with optional session scoping.
    # Joins back to events table for session_id and event_type.
    #
    # @return [Array<Hash>] raw database rows
    def execute_fts_query
      sql = if @session_id
        Arel.sql(scoped_sql, @recency_decay, @terms, @session_id, @limit)
      else
        Arel.sql(global_sql, @recency_decay, @terms, @limit)
      end

      connection.select_all(sql, "Mneme::Search").to_a
    end

    # FTS5 query across all sessions.
    # Contentless FTS5 can't use snippet() — extract content from events directly.
    #
    # Ranking blends BM25 relevance with recency: rank is negative (more
    # negative = better match), so dividing by a factor > 1 for older events
    # moves them closer to zero (less relevant). At decay 0.3, a one-year-old
    # result needs ~30% better keyword relevance to beat an identical match
    # from today.
    def global_sql
      <<~SQL
        SELECT
          e.id AS event_id,
          e.session_id,
          e.event_type,
          CASE
            WHEN e.event_type IN ('user_message', 'agent_message', 'system_message')
              THEN substr(json_extract(e.payload, '$.content'), 1, 300)
            WHEN e.event_type = 'tool_call'
              THEN substr(json_extract(e.payload, '$.tool_input.thoughts'), 1, 300)
          END AS snippet,
          rank / (1.0 + ? * (julianday('now') - julianday(e.created_at)) / 365.0) AS rank
        FROM events_fts
        JOIN events e ON e.id = events_fts.rowid
        WHERE events_fts MATCH ?
        ORDER BY rank
        LIMIT ?
      SQL
    end

    # FTS5 query scoped to a specific session.
    def scoped_sql
      <<~SQL
        SELECT
          e.id AS event_id,
          e.session_id,
          e.event_type,
          CASE
            WHEN e.event_type IN ('user_message', 'agent_message', 'system_message')
              THEN substr(json_extract(e.payload, '$.content'), 1, 300)
            WHEN e.event_type = 'tool_call'
              THEN substr(json_extract(e.payload, '$.tool_input.thoughts'), 1, 300)
          END AS snippet,
          rank / (1.0 + ? * (julianday('now') - julianday(e.created_at)) / 365.0) AS rank
        FROM events_fts
        JOIN events e ON e.id = events_fts.rowid
        WHERE events_fts MATCH ?
          AND e.session_id = ?
        ORDER BY rank
        LIMIT ?
      SQL
    end

    FRIENDLY_EVENT_TYPES = {
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
      raw_type = row["event_type"]
      Result.new(
        event_id: row["event_id"],
        session_id: row["session_id"],
        snippet: row["snippet"],
        rank: row["rank"],
        event_type: FRIENDLY_EVENT_TYPES.fetch(raw_type, raw_type)
      )
    end

    # Sanitizes user input for FTS5 MATCH safety.
    # Strips special FTS5 operators that could cause syntax errors,
    # keeps only alphanumeric words and quoted phrases.
    #
    # @param raw [String]
    # @return [String] safe FTS5 query
    def sanitize_query(raw)
      return "" unless raw

      # Extract quoted phrases and individual words, drop FTS5 operators
      tokens = raw.scan(/"[^"]+?"|\S+/).reject { |token| token.match?(/\A[*:^{}()]+\z/) }
      tokens.filter_map { |token| sanitize_token(token) }.join(" ")
    end

    def sanitize_token(token)
      return token if token.start_with?('"')

      cleaned = token.gsub(/[^a-zA-Z0-9-]/, "")
      cleaned.empty? ? nil : cleaned
    end

    def connection
      ActiveRecord::Base.connection
    end
  end
end
