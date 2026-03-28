# frozen_string_literal: true

module Tools
  # Active memory search — keyword lookup across conversation history.
  # Returns ranked snippets with message IDs for drill-down via {Remember}.
  #
  # Two-step memory workflow:
  #   1. `recall(query: "auth flow")` → discovers relevant messages
  #   2. `remember(message_id: 42)` → fractal zoom into full context
  #
  # Wraps {Mneme::Search} — same FTS5 engine used by passive recall,
  # but triggered on demand by the agent instead of automatically by goals.
  #
  # @example Search all sessions
  #   recall(query: "authentication flow")
  #
  # @example Search current session only
  #   recall(query: "OAuth config", session_only: true)
  class Recall < Base
    def self.tool_name = "recall"

    def self.description = "Search all past conversations by keywords (FTS5 full-text search). " \
      "Returns ranked snippets with message IDs — use remember(message_id:) to zoom into full context. " \
      "Searches all sessions by default; set session_only: true to restrict to current session."

    def self.input_schema
      {
        type: "object",
        properties: {
          query: {type: "string", description: "Search keywords or phrase"},
          session_only: {type: "boolean", description: "Search current session only (default: all sessions)"}
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
    # Each result includes message_id for drill-down via remember tool.
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
