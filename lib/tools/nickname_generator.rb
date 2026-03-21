# frozen_string_literal: true

module Tools
  # Generates short, memorable nicknames for generic sub-agents using a
  # fast LLM call. Nicknames serve as @mention handles for bidirectional
  # parent ↔ child communication.
  #
  # Named specialists already have names from their definition files and
  # skip nickname generation entirely.
  #
  # @example
  #   NicknameGenerator.call("Read agent_loop.rb and summarize tool flow", parent_session)
  #   #=> "loop-sleuth"
  module NicknameGenerator
    SYSTEM_PROMPT = <<~PROMPT
      Generate a short, memorable nickname for a sub-agent based on its task.
      Rules:
      - 1-3 lowercase words joined by hyphens (e.g. "loop-sleuth", "api-scout")
      - Evocative of the task, fun, easy to type after @
      - No emoji, no spaces, no uppercase
      - Respond with ONLY the nickname, nothing else
    PROMPT

    class << self
      # Generates a unique nickname for a sub-agent.
      # Falls back to "agent-N" on transient LLM failures (rate limits,
      # timeouts, server errors). Auth and config errors propagate.
      #
      # @param task [String] the sub-agent's task description
      # @param parent_session [Session] the parent session (for uniqueness check)
      # @return [String] a unique nickname
      def call(task, parent_session)
        nickname = generate(task)
        ensure_unique(nickname, parent_session)
      rescue Providers::Anthropic::TransientError => error
        Rails.logger.warn("Nickname generation failed (transient): #{error.message}")
        fallback_nickname(parent_session)
      end

      private

      def generate(task)
        client = LLM::Client.new(
          model: Anima::Settings.fast_model,
          max_tokens: 32
        )
        raw = client.chat(
          [{role: "user", content: "Task: #{task}"}],
          system: SYSTEM_PROMPT
        )
        sanitize(raw)
      end

      # Strips whitespace and non-word/non-hyphen characters.
      def sanitize(raw)
        raw.to_s.strip.downcase.gsub(/[^\w-]/, "").truncate(50, omission: "")
      end

      # Appends a numeric suffix if the name collides with an existing sibling.
      def ensure_unique(nickname, parent_session)
        existing = parent_session.child_sessions.pluck(:name).compact
        return nickname unless existing.include?(nickname)

        counter = 2
        counter += 1 while existing.include?("#{nickname}-#{counter}")
        "#{nickname}-#{counter}"
      end

      def fallback_nickname(parent_session)
        count = parent_session.child_sessions.count + 1
        "agent-#{count}"
      end
    end
  end
end
