# frozen_string_literal: true

# Counts tokens in an event's payload via the Anthropic API and
# caches the result on the event record. Enqueued automatically
# after each LLM event is created.
class CountEventTokensJob < ApplicationJob
  queue_as :default

  retry_on Providers::Anthropic::Error, wait: :polynomially_longer, attempts: 3
  discard_on ActiveRecord::RecordNotFound

  # @param event_id [Integer] the Event record to count tokens for
  def perform(event_id)
    event = Event.find(event_id)
    return if already_counted?(event)

    provider = Providers::Anthropic.new
    messages = [{role: event.api_role, content: event.payload["content"].to_s}]

    token_count = provider.count_tokens(
      model: LLM::Client::DEFAULT_MODEL,
      messages: messages
    )

    # Guard against parallel jobs: reload and re-check before writing.
    # Uses update! (not update_all) so {Event::Broadcasting} after_update_commit
    # broadcasts the updated token count to connected clients.
    event.reload
    return if already_counted?(event)

    event.update!(token_count: token_count)
  end

  private

  def already_counted?(event)
    event.token_count > 0
  end
end
