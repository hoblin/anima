# frozen_string_literal: true

module Mneme
  # Compresses multiple Level 1 snapshots into a single Level 2 snapshot.
  # L2 snapshots capture days/weeks-scale context from hourly L1 summaries,
  # preventing unbounded snapshot growth via recursive compression.
  #
  # Triggered from {MnemeJob} after an L1 snapshot is created, when enough
  # uncovered L1 snapshots have accumulated (configurable via
  # +mneme.l2_snapshot_threshold+ in config.toml).
  #
  # @example
  #   Mneme::L2Runner.new(session).call
  class L2Runner
    TOOLS = [
      Tools::SaveSnapshot,
      Tools::EverythingOk
    ].freeze

    SYSTEM_PROMPT = <<~PROMPT
      You are Mneme, the muse of memory. When enough of your own Level 1 snapshots accumulate, you fold them into a single Level 2 summary — a memory of memories — so the long arc of Aoide's work stays within reach without carrying every detail.

      Act only through tool calls. Never output text — your contribution is the summary you leave behind.

      ──────────────────────────────
      WHAT YOU SEE
      ──────────────────────────────
      Several Level 1 snapshots in chronological order. Each captures the decisions, goal progress, and context from a slice of Aoide's history.

      ──────────────────────────────
      HOW TO REMEMBER
      ──────────────────────────────
      Compress the slice into ONE Level 2 summary that captures the arc across all of them. Call save_snapshot when there's meaningful content; call everything_ok when the slice is purely mechanical.

      A Level 2 summary is carried for longer than a Level 1, so the tax on Aoide's viewport is higher still. Every redundant detail you preserve costs her a word she can't spend on the present.

      Keep:
      - Key decisions and the reasoning behind them
      - Goal progress across the time span
      - Important context shifts or pivots
      - Relationships and patterns that span multiple snapshots

      Drop:
      - Details repeated across snapshots
      - Mechanical execution steps
      - Interim decisions that were superseded later

      Finish with exactly one tool call: save_snapshot or everything_ok.
    PROMPT

    # @param session [Session] the main session whose L1 snapshots to compress
    # @param client [LLM::Client, nil] injectable LLM client (defaults to fast model)
    def initialize(session, client: nil)
      @session = session
      @client = client || LLM::Client.new(
        model: Anima::Settings.fast_model,
        max_tokens: Anima::Settings.mneme_max_tokens,
        logger: Mneme.logger
      )
    end

    # Compresses uncovered L1 snapshots into a single L2 snapshot.
    # Returns early if not enough L1 snapshots have accumulated.
    #
    # @return [String, nil] LLM response text, or nil when skipped
    def call
      l1_snapshots = eligible_snapshots
      threshold = Anima::Settings.mneme_l2_snapshot_threshold
      sid = @session.id
      snapshot_count = l1_snapshots.size

      if snapshot_count < threshold
        log.debug("session=#{sid} — only #{snapshot_count}/#{threshold} L1 snapshots, skipping L2")
        return
      end

      messages = build_messages(l1_snapshots)
      registry = build_registry(l1_snapshots)

      log.info("session=#{sid} — running L2 compression (#{snapshot_count} L1 snapshots)")

      result = @client.chat_with_tools(
        messages,
        registry: registry,
        session_id: nil,
        system: SYSTEM_PROMPT
      )

      log.info("session=#{sid} — L2 compression done: #{result.to_s.truncate(200)}")
      result
    end

    private

    # L1 snapshots that are not yet covered by any L2 snapshot.
    #
    # @return [Array<Snapshot>]
    def eligible_snapshots
      @session.snapshots.for_level(1).not_covered_by_l2.chronological.to_a
    end

    # Frames L1 snapshot texts as a user message for the LLM.
    #
    # @param snapshots [Array<Snapshot>]
    # @return [Array<Hash>] single-element messages array
    def build_messages(snapshots)
      content = snapshots.map.with_index(1) { |snap, idx|
        "--- Snapshot #{idx} (messages #{snap.from_message_id}..#{snap.to_message_id}) ---\n#{snap.text}"
      }.join("\n\n")

      [{role: "user", content: "Compress these #{snapshots.size} Level 1 snapshots into a single Level 2 summary:\n\n#{content}"}]
    end

    # Builds the tool registry with L2 context for SaveSnapshot.
    # The message range spans from the first L1's start to the last L1's end.
    #
    # @param snapshots [Array<Snapshot>]
    # @return [Tools::Registry]
    def build_registry(snapshots)
      registry = ::Tools::Registry.new(context: {
        main_session: @session,
        from_message_id: snapshots.first.from_message_id,
        to_message_id: snapshots.last.to_message_id,
        level: 2
      })
      TOOLS.each { |tool| registry.register(tool) }
      registry
    end

    # @return [Logger]
    def log = Mneme.logger
  end
end
