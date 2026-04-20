# frozen_string_literal: true

module Mneme
  # Passive recall — automatic memory surfacing triggered by Goal updates.
  # When goals are created or updated, searches message history for related
  # context and enqueues phantom tool_call/tool_response pairs via the
  # PendingMessage pipeline.
  #
  # Phantom pairs are promoted into real Message records by
  # {DrainJob} between rounds, then
  # ride the conveyor belt like regular messages — cached as part of the
  # stable prefix, compressed by Mneme on eviction.
  #
  # @example Trigger after a goal update
  #   Mneme::PassiveRecall.new(session).call
  class PassiveRecall
    # Estimated token overhead for a tool_use wrapper (name + input fields).
    TOOL_PAIR_OVERHEAD_TOKENS = 50

    # @param session [Session] the session whose goals drive recall
    def initialize(session)
      @session = session
    end

    # Searches message history using active goal descriptions as queries.
    # Enqueues phantom recall pairs for new results not already recalled.
    #
    # @return [Integer] number of pending messages created
    def call
      goals = @session.goals.active.root.includes(:sub_goals)
      return 0 if goals.empty?

      search_terms = build_search_terms(goals)
      return 0 if search_terms.blank?

      results = Mneme::Search.query(search_terms, limit: Anima::Settings.recall_max_results)
      results = filter_duplicates(results)
      results = gate_for_relevance(results, goals)

      enqueue_pending_messages(results)
    end

    private

    # Runs the relevance gate on the remaining candidates. Empty input
    # short-circuits the LLM call.
    #
    # @param results [Array<Mneme::Search::Result>]
    # @param goals [ActiveRecord::Relation<Goal>]
    # @return [Array<Mneme::Search::Result>]
    def gate_for_relevance(results, goals)
      return results if results.empty?

      RelevanceGate.new(goals: goals, candidates: results).call
    end

    STOP_WORDS = Set.new(%w[
      a an the is are was were be been being do does did
      have has had in on at to for of and or but not with
      this that it its by from as up out if about into
      fix add create update remove implement check set get
    ]).freeze

    # Extracts meaningful keywords from active goals and joins with OR.
    #
    # @param goals [ActiveRecord::Relation<Goal>]
    # @return [String] FTS5 OR-joined keywords
    def build_search_terms(goals)
      descriptions = goals.flat_map { |goal|
        [goal.description] + goal.sub_goals.reject(&:completed?).map(&:description)
      }

      words = descriptions.join(" ")
        .gsub(/[^a-zA-Z0-9\s-]/, "")
        .downcase
        .split
        .uniq
        .reject { |word| STOP_WORDS.include?(word) || word.length < 3 }

      words.join(" OR ").truncate(500)
    end

    # Excludes results whose content Aoide has already seen in this session:
    # live viewport messages, phantom recall pairs previously promoted, and
    # recalls still waiting in the mailbox. All three sets work on the raw
    # original message_id so a single set difference suffices.
    #
    # @param results [Array<Mneme::Search::Result>]
    # @return [Array<Mneme::Search::Result>]
    def filter_duplicates(results)
      already_surfaced = already_surfaced_message_ids
      results.reject { |result| already_surfaced.include?(result.message_id) }
    end

    # Message IDs that have already reached Aoide's context in this session,
    # through any of the three channels memory moves through:
    #   1. the live viewport (original message still above the boundary);
    #   2. a promoted `from_mneme` phantom pair (the message_id is stored
    #      inside `tool_input.message_id` on the tool_call row);
    #   3. a recall PendingMessage waiting in the mailbox (`source_name`
    #      carries the message_id as a string).
    #
    # @return [Set<Integer>]
    def already_surfaced_message_ids
      viewport_ids = @session.viewport_messages.pluck(:id).to_set

      promoted_recall_ids = @session.messages
        .where(message_type: "tool_call")
        .where("payload ->> 'tool_name' = ?", PendingMessage::MNEME_TOOL)
        .pluck(Arel.sql("json_extract(payload, '$.tool_input.message_id')"))
        .compact
        .map(&:to_i)
        .to_set

      pending_recall_ids = @session.pending_messages
        .where(source_type: "recall")
        .pluck(:source_name)
        .map(&:to_i)
        .to_set

      viewport_ids | promoted_recall_ids | pending_recall_ids
    end

    # Creates PendingMessages for each recall result.
    #
    # @param results [Array<Mneme::Search::Result>]
    # @return [Integer] number of pending messages created
    def enqueue_pending_messages(results)
      messages_by_id = Message.where(id: results.map(&:message_id))
        .includes(:session).index_by(&:id)

      count = 0
      remaining = (Anima::Settings.token_budget * Anima::Settings.recall_budget_fraction).to_i

      results.each do |result|
        snippet = format_snippet(result, messages_by_id)
        cost = TokenEstimation.estimate_token_count(snippet) + TOOL_PAIR_OVERHEAD_TOKENS
        break if cost > remaining && count > 0

        @session.pending_messages.create!(
          content: snippet,
          source_type: "recall",
          source_name: result.message_id.to_s,
          message_type: "from_mneme"
        )

        remaining -= cost
        count += 1
      end

      count
    end

    # Formats a search result as a compact snippet.
    #
    # @param result [Mneme::Search::Result]
    # @param messages_by_id [Hash{Integer => Message}] pre-fetched messages
    # @return [String]
    def format_snippet(result, messages_by_id)
      msg = messages_by_id[result.message_id]
      session_label = msg&.session&.name || "session ##{result.session_id}"
      content = result.snippet.truncate(Anima::Settings.recall_max_snippet_tokens * TokenEstimation::BYTES_PER_TOKEN)
      "message #{result.message_id} (#{session_label}): #{content}"
    end
  end
end
