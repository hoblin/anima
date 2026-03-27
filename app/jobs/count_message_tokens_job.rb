# frozen_string_literal: true

# Counts tokens in a message's payload via the Anthropic API and
# caches the result on the message record. Enqueued automatically
# after each LLM message is created.
class CountMessageTokensJob < ApplicationJob
  queue_as :default

  retry_on Providers::Anthropic::Error, wait: :polynomially_longer, attempts: 3
  discard_on ActiveRecord::RecordNotFound

  # @param message_id [Integer] the Message record to count tokens for
  def perform(message_id)
    message = Message.find(message_id)
    return if already_counted?(message)

    provider = Providers::Anthropic.new
    api_messages = [{role: message.api_role, content: message.payload["content"].to_s}]

    token_count = provider.count_tokens(
      model: Anima::Settings.model,
      messages: api_messages
    )

    # Guard against parallel jobs: reload and re-check before writing.
    # Uses update! (not update_all) so {Message::Broadcasting} after_update_commit
    # broadcasts the updated token count to connected clients.
    message.reload
    return if already_counted?(message)

    message.update!(token_count: token_count)
  end

  private

  def already_counted?(message)
    message.token_count > 0
  end
end
