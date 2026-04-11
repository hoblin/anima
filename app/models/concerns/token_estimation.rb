# frozen_string_literal: true

# Shared token-count lifecycle for records that ride in the LLM context
# window. Including models seed {#token_count} with a local heuristic on
# create and schedule {CountTokensJob} to refine it with the real Anthropic
# tokenizer count.
#
# Non-AR callers (TUI debug display, phantom-pair sizing, byte-cap
# calculations) use {.estimate_token_count} and {BYTES_PER_TOKEN} as
# module-level helpers without including the concern.
#
# Including models must implement +#tokenization_text+ returning the
# string whose token count should be estimated and later refined.
module TokenEstimation
  extend ActiveSupport::Concern

  # Heuristic: average bytes per token for English prose.
  BYTES_PER_TOKEN = 4

  # Estimates token count from a string using the {BYTES_PER_TOKEN} heuristic.
  #
  # @param text [String, nil]
  # @return [Integer] estimated token count (0 for blank input)
  def self.estimate_token_count(text)
    (text.to_s.bytesize / BYTES_PER_TOKEN.to_f).ceil
  end

  included do
    before_validation :set_estimated_token_count, on: :create
    after_create :schedule_token_count
  end

  # Heuristic token estimate for this record's {#tokenization_text}.
  #
  # @return [Integer]
  def estimate_tokens
    TokenEstimation.estimate_token_count(tokenization_text)
  end

  private

  # Seeds {#token_count} with a local estimate before the record is saved.
  # Respects an explicit positive value passed by the caller (e.g. tests
  # that want deterministic counts).
  def set_estimated_token_count
    return if token_count.to_i.positive?

    self.token_count = estimate_tokens
  end

  def schedule_token_count
    CountTokensJob.perform_later(self)
  end
end
