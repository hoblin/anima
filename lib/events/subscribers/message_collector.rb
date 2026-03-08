# frozen_string_literal: true

module Events
  module Subscribers
    # Collects chat-displayable events in-memory for the current session.
    # Provides the message list that the TUI renders and the LLM client consumes.
    #
    # Only user_message and agent_message events are collected — system_message,
    # tool_call, and tool_response are internal and not part of the chat display.
    #
    # @example
    #   collector = Events::Subscribers::MessageCollector.new
    #   Events::Bus.subscribe(collector)
    #   collector.messages # => [{role: "user", content: "hi"}, ...]
    class MessageCollector
      include Events::Subscriber

      DISPLAYABLE_TYPES = %w[user_message agent_message].freeze

      # Maps event types to LLM-compatible role identifiers
      ROLE_MAP = {
        "user_message" => "user",
        "agent_message" => "assistant"
      }.freeze

      def initialize
        @messages = []
        @mutex = Mutex.new
      end

      # @return [Array<Hash>] thread-safe copy of collected messages
      def messages
        @mutex.synchronize { @messages.dup }
      end

      # Receives a Rails.event notification hash.
      # @param event [Hash] with :payload containing :type and :content keys
      def emit(event)
        type = event.dig(:payload, :type)
        return unless DISPLAYABLE_TYPES.include?(type)

        content = event.dig(:payload, :content)
        return if content.nil?

        @mutex.synchronize do
          @messages << {
            role: ROLE_MAP.fetch(type),
            content: content
          }
        end
      end

      def clear
        @mutex.synchronize { @messages = [] }
      end
    end
  end
end
