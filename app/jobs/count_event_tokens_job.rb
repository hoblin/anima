# frozen_string_literal: true

# Counts tokens in an event's payload via the Anthropic API and
# caches the result on the event record. Enqueued automatically
# after each event is created.
class CountEventTokensJob < ApplicationJob
  queue_as :default

  retry_on Providers::Anthropic::Error, wait: 5.seconds, attempts: 3
  discard_on ActiveRecord::RecordNotFound

  # @param event_id [Integer] the Event record to count tokens for
  def perform(event_id)
    event = Event.find(event_id)
    return if event.token_count > 0

    provider = Providers::Anthropic.new
    role = (event.event_type == "user_message") ? "user" : "assistant"
    messages = [{role: role, content: event.payload["content"].to_s}]

    token_count = provider.count_tokens(
      model: LLM::Client::DEFAULT_MODEL,
      messages: messages
    )

    event.update_column(:token_count, token_count)
  end
end
