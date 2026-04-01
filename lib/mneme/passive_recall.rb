# frozen_string_literal: true

module Mneme
  # Passive recall — automatic memory surfacing triggered by Goal updates.
  # When goals are created or updated, searches message history for related
  # context and enqueues phantom tool_call/tool_response pairs via the
  # PendingMessage pipeline.
  #
  # Phantom pairs are promoted into real Message records by
  # {Session#promote_pending_messages!} between agent loop rounds, then
  # ride the conveyor belt like regular messages — cached as part of the
  # stable prefix, compressed by Mneme on eviction.
  #
  # @example Trigger after a goal update
  #   Mneme::PassiveRecall.new(session).call
  class PassiveRecall
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

      enqueue_pending_messages(results)
    end

    private

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

    # Excludes results already in the viewport or already recalled (pending or promoted).
    #
    # @param results [Array<Mneme::Search::Result>]
    # @return [Array<Mneme::Search::Result>]
    def filter_duplicates(results)
      viewport_ids = @session.viewport_message_ids.to_set

      existing_recall_ids = @session.messages
        .where(message_type: "tool_call")
        .where("payload ->> 'tool_name' = ?", PendingMessage::RECALL_TOOL_NAME)
        .pluck(:tool_use_id)
        .to_set

      pending_recall_ids = @session.pending_messages
        .where(source_type: "recall")
        .pluck(:source_name)
        .map { |name| "recall_#{name}" }
        .to_set

      known_ids = existing_recall_ids | pending_recall_ids

      results.reject { |result|
        viewport_ids.include?(result.message_id) ||
          known_ids.include?("recall_#{result.message_id}")
      }
    end

    # Creates PendingMessages for each recall result.
    #
    # @param results [Array<Mneme::Search::Result>]
    # @return [Integer] number of pending messages created
    def enqueue_pending_messages(results)
      count = 0
      remaining = (Anima::Settings.token_budget * Anima::Settings.recall_budget_fraction).to_i

      results.each do |result|
        snippet = format_snippet(result)
        cost = Message.estimate_token_count(snippet.bytesize) + 50
        break if cost > remaining && count > 0

        @session.pending_messages.create!(
          content: snippet,
          source_type: "recall",
          source_name: result.message_id.to_s
        )

        remaining -= cost
        count += 1
      end

      count
    end

    # Formats a search result as a compact snippet.
    #
    # @param result [Mneme::Search::Result]
    # @return [String]
    def format_snippet(result)
      msg = Message.find_by(id: result.message_id)
      return result.snippet unless msg

      session_label = msg.session&.name || "session ##{result.session_id}"
      content = result.snippet.truncate(Anima::Settings.recall_max_snippet_tokens * Message::BYTES_PER_TOKEN)
      "message #{result.message_id} (#{session_label}): #{content}"
    end
  end
end
