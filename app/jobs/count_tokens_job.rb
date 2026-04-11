# frozen_string_literal: true

# Refines a record's +token_count+ with the real Anthropic tokenizer count,
# replacing the local heuristic seeded during creation. Accepts any record
# that includes {TokenEstimation} and implements +#tokenization_text+ —
# Messages, Snapshots, and PinnedMessages share the same pipeline.
class CountTokensJob < ApplicationJob
  queue_as :default

  retry_on Providers::Anthropic::Error, wait: :polynomially_longer, attempts: 3
  discard_on ActiveRecord::RecordNotFound

  # @param record [ActiveRecord::Base] any record responding to
  #   +#tokenization_text+ and +token_count=+
  def perform(record)
    count = Providers::Anthropic.new.count_tokens(
      model: Anima::Settings.model,
      messages: [{role: "user", content: record.tokenization_text}]
    )

    record.update!(token_count: count)
  end
end
