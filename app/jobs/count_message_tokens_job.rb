# frozen_string_literal: true

# Refines a message's {Message#token_count} with the real Anthropic
# tokenizer count, replacing the local estimate seeded during creation.
# Enqueued automatically after every message is created, regardless of
# message type.
class CountMessageTokensJob < ApplicationJob
  queue_as :default

  retry_on Providers::Anthropic::Error, wait: :polynomially_longer, attempts: 3
  discard_on ActiveRecord::RecordNotFound

  # @param message_id [Integer] the Message record to count tokens for
  def perform(message_id)
    message = Message.find(message_id)
    api_messages = build_api_messages(message)
    return if api_messages.nil?

    count = Providers::Anthropic.new.count_tokens(
      model: Anima::Settings.model,
      messages: api_messages
    )

    message.update!(token_count: count)
  end

  private

  # Builds the messages payload to send to the count_tokens endpoint.
  # LLM messages preserve their role for accurate tokenization. Tool
  # messages serialize their full payload as JSON so tool_name, tool_input,
  # and tool_use_id contribute to the count — they ride as a user message
  # because a standalone tool_use can't be sent without its tool_result.
  # System messages use their content as a user message.
  #
  # @param message [Message]
  # @return [Array<Hash>, nil] API messages, or nil if nothing to count
  def build_api_messages(message)
    case message.message_type
    when "user_message", "agent_message"
      content = message.payload["content"].to_s
      return nil if content.empty?
      [{role: message.api_role, content: content}]
    when "system_message"
      content = message.payload["content"].to_s
      return nil if content.empty?
      [{role: "user", content: content}]
    when "tool_call", "tool_response"
      [{role: "user", content: message.payload.to_json}]
    end
  end
end
