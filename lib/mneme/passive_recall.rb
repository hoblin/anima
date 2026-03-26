# frozen_string_literal: true

module Mneme
  # Passive recall — automatic memory surfacing triggered by Goal updates.
  # When goals are created or updated, searches event history for related
  # context and caches the results on the session for viewport injection.
  #
  # The agent never calls a tool; relevant memories appear automatically
  # in the viewport between snapshots and the sliding window. This mirrors
  # recognition memory in humans — context surfaces without conscious effort.
  #
  # @example Trigger after a goal update
  #   Mneme::PassiveRecall.new(session).call
  class PassiveRecall
    # @param session [Session] the session whose goals drive recall
    def initialize(session)
      @session = session
    end

    # Searches event history using active goal descriptions as queries.
    # Returns recall results suitable for viewport injection.
    #
    # @return [Array<Mneme::Search::Result>] deduplicated, relevance-sorted
    def call
      goals = @session.goals.active.root.includes(:sub_goals)
      return [] if goals.empty?

      search_terms = build_search_terms(goals)
      return [] if search_terms.blank?

      results = Mneme::Search.query(search_terms, limit: Anima::Settings.recall_max_results)

      # Exclude events from the current session's viewport — no point recalling
      # what the agent already sees.
      viewport_ids = @session.viewport_message_ids.to_set
      results.reject { |result| viewport_ids.include?(result.message_id) }
    end

    private

    STOP_WORDS = Set.new(%w[
      a an the is are was were be been being do does did
      have has had in on at to for of and or but not with
      this that it its by from as up out if about into
      fix add create update remove implement check set get
    ]).freeze

    # Extracts meaningful keywords from active goals and joins with OR.
    # Stop words and generic verbs are stripped — they're too common to
    # produce useful recall results.
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
  end
end
