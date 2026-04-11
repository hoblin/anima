# frozen_string_literal: true

module Tools
  # Keyword search across long-term memory — every message Anima has
  # ever seen, across every session. Wraps {Mneme::Search} (FTS5) and
  # returns ranked snippets with message IDs for drill-down via
  # {ViewMessages}.
  #
  # Two-step memory workflow:
  #   1. `search_messages(query: "auth flow")` → discovers relevant messages
  #   2. `view_messages(message_id: 42)` → fractal zoom into full context
  #
  # Same FTS5 engine Mneme uses for passive recall — but this variant
  # fires on demand when Aoide reaches for a memory herself.
  #
  # @example Search across all sessions
  #   search_messages(query: "authentication flow")
  #
  # @example Restrict to the current session
  #   search_messages(query: "OAuth config", session_only: true)
  class SearchMessages < Base
    def self.tool_name = "search_messages"

    def self.description = "Search long-term memory (past conversations) by keyword. Returns ranked message snippets with IDs — pass any ID to view_messages to see the full context around it."

    def self.input_schema
      {
        type: "object",
        properties: {
          query: {type: "string"},
          session_only: {type: "boolean", description: "Default: all sessions"}
        },
        required: ["query"]
      }
    end

    # @param session [Session] the current session (used for session_only scoping)
    def initialize(session:, **)
      @session = session
    end

    # @param input [Hash] with "query" and optional "session_only"
    # @return [String] formatted search results with message IDs
    # @return [Hash] with :error key when query is blank
    def execute(input)
      query = input["query"].to_s.strip
      return {error: "Query cannot be blank"} if query.empty?

      session_id = (input["session_only"] == true) ? @session.id : nil
      results = Mneme::Search.query(query, session_id: session_id)

      return "No results found for \"#{query}\"." if results.empty?

      format_results(query, results)
    end

    private

    # Formats results as token-efficient, LLM-readable output.
    # Each result includes message_id for drill-down via view_messages.
    #
    # @param query [String] the original search query
    # @param results [Array<Mneme::Search::Result>] ranked search results
    # @return [String] formatted output
    def format_results(query, results)
      session_names = load_session_names(results)

      result_word = (results.size == 1) ? "result" : "results"
      lines = ["Found #{results.size} #{result_word} for \"#{query}\":", ""]
      results.each { |result| lines.concat(format_single_result(result, session_names)) }
      lines.join("\n")
    end

    # Formats a single search result as display lines.
    #
    # @param result [Mneme::Search::Result]
    # @param session_names [Hash{Integer => String}]
    # @return [Array<String>]
    def format_single_result(result, session_names)
      sid = result.session_id
      session_name = session_names[sid] || "Session ##{sid}"
      snippet = result.snippet.to_s.gsub(/\s+/, " ").strip

      [
        "[message #{result.message_id}, session \"#{session_name}\", #{result.message_type}]",
        "  ...#{snippet}...",
        ""
      ]
    end

    # Batch-loads session names to avoid N+1 queries.
    #
    # @param results [Array<Mneme::Search::Result>]
    # @return [Hash{Integer => String}] session_id => name
    def load_session_names(results)
      session_ids = results.map(&:session_id).uniq
      Session.where(id: session_ids).pluck(:id, :name).to_h
    end
  end
end
