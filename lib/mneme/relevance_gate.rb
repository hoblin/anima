# frozen_string_literal: true

module Mneme
  # Post-search relevance gate for {PassiveRecall}. FTS5 casts a wide net —
  # any keyword overlap with active goals promotes a message to a candidate.
  # The gate asks a fast model to judge which candidates are actually useful
  # to Aoide right now, so only high-signal memories reach the conversation.
  #
  # The gate favors silence: when in doubt, drop the candidate. Returning
  # fewer, sharper recalls beats comprehensive noise.
  #
  # @example
  #   filtered = Mneme::RelevanceGate.new(
  #     goals_description: "Fix authentication flow",
  #     candidates: search_results
  #   ).call
  class RelevanceGate
    SYSTEM_PROMPT = <<~PROMPT
      You are the relevance gate of Mneme, the muse of memory. Aoide is working on a goal. Full-text search has surfaced candidate memories from past conversations that share keywords with the goal. Most of them will be noise — keyword overlap without substance.

      Your task: keep only the memories that would measurably help Aoide with her current goal. Be strict. Prefer returning nothing over returning noise. Tangential, mildly-related, or merely-interesting memories fail the gate.

      Respond with JSON only, no prose:
      {"keep": [<message_id>, <message_id>, ...]}

      Use {"keep": []} when nothing clears the threshold.
    PROMPT

    # @param goals [Enumerable<Goal>] active root goals (each may expose :sub_goals)
    # @param candidates [Array<Mneme::Search::Result>] FTS5 results already dedup'd
    # @param client [LLM::Client, nil] injectable client; defaults to fast model
    def initialize(goals:, candidates:, client: nil)
      @goals = goals
      @candidates = candidates
      @client = client || default_client
    end

    # Runs the gate and returns only the candidates the LLM kept. Empty
    # input short-circuits without an API call.
    #
    # @return [Array<Mneme::Search::Result>]
    def call
      return @candidates if @candidates.empty?

      response = @client.chat_with_tools(
        [{role: "user", content: user_message}],
        registry: ::Tools::Registry.new,
        system: SYSTEM_PROMPT
      )

      kept_ids = parse_keep_ids(response[:text])
      @candidates.select { |candidate| kept_ids.include?(candidate.message_id) }
    end

    private

    def default_client
      LLM::Client.new(
        model: Anima::Settings.fast_model,
        max_tokens: Anima::Settings.recall_relevance_gate_max_tokens,
        logger: Mneme.logger
      )
    end

    # Renders goals + candidate snippets as the user-side prompt.
    #
    # @return [String]
    def user_message
      candidate_lines = @candidates.map { |candidate|
        "- message #{candidate.message_id}: #{candidate.snippet.to_s.truncate(300)}"
      }

      <<~MSG.strip
        Aoide's current goal(s):
        #{render_goals}

        Candidate memories:
        #{candidate_lines.join("\n")}
      MSG
    end

    # Flattens root goals and their open sub-goals into a bulleted list.
    #
    # @return [String]
    def render_goals
      @goals.flat_map { |goal|
        ["- #{goal.description}"] +
          goal.sub_goals.reject(&:completed?).map { |sub| "  • #{sub.description}" }
      }.join("\n")
    end

    # Extracts the `keep` array from the model's JSON response.
    # Finds the first JSON object in the text — models occasionally wrap
    # the object in a fence despite the instruction.
    #
    # @param text [String] raw LLM response
    # @return [Set<Integer>] ids to keep (empty set when the array is empty)
    def parse_keep_ids(text)
      json = text.to_s[/\{.*\}/m]
      raise ArgumentError, "RelevanceGate: no JSON object in response: #{text.inspect}" unless json

      parsed = JSON.parse(json)
      Array(parsed["keep"]).map(&:to_i).to_set
    end
  end
end
