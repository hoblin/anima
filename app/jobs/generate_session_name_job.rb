# frozen_string_literal: true

# Generates a short, descriptive name for a session using a fast LLM.
# Enqueued by {Session#schedule_name_generation!} after the first exchange
# and again every {Session::NAME_GENERATION_INTERVAL} messages so the name
# stays relevant as the conversation evolves.
#
# Always overwrites the existing name — scheduling guards in the model
# control when regeneration is appropriate.
#
# @example
#   GenerateSessionNameJob.perform_later(session.id)
class GenerateSessionNameJob < ApplicationJob
  queue_as :default

  retry_on Providers::Anthropic::TransientError,
    wait: :polynomially_longer, attempts: 3

  discard_on ActiveRecord::RecordNotFound
  discard_on Providers::Anthropic::AuthenticationError

  NAMING_PROMPT = <<~PROMPT
    Generate a fun name for this chat session: one emoji followed by 1-3 words.
    Be creative and playful. Respond with ONLY the name, nothing else.
  PROMPT

  # How many conversation events to feed as context for naming.
  MAX_CONTEXT_EVENTS = 6

  # Tight token limit — we only need a few words back.
  MAX_TOKENS = 32

  # @param session_id [Integer] the Session to name
  def perform(session_id)
    session = Session.find(session_id)

    context = build_context(session)
    return if context.blank?

    client = LLM::Client.new(model: LLM::Client::FAST_MODEL, max_tokens: MAX_TOKENS)
    name = client.chat([{role: "user", content: "#{NAMING_PROMPT}\nConversation:\n#{context}"}])

    session.update!(name: name.strip.truncate(255))
  end

  private

  # Builds a condensed transcript from the earliest LLM messages.
  # Each message is truncated to 200 chars to keep the naming prompt cheap.
  #
  # @param session [Session]
  # @return [String] "User: ...\nAssistant: ..." transcript
  def build_context(session)
    session.events.llm_messages.order(:id).limit(MAX_CONTEXT_EVENTS).map { |event|
      role = (event.event_type == "user_message") ? "User" : "Assistant"
      "#{role}: #{event.payload["content"].to_s.truncate(200)}"
    }.join("\n")
  end
end
