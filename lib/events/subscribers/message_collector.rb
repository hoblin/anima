# frozen_string_literal: true

module Events
  module Subscribers
    # Collects chat-displayable events in-memory for the current session.
    # Provides the message list that the TUI renders and the LLM client consumes.
    #
    # @example
    #   collector = Events::Subscribers::MessageCollector.new
    #   Events::Bus.subscribe(collector)
    #   collector.messages # => [{role: "user", content: "hi"}, ...]
    class MessageCollector
      DISPLAYABLE_TYPES = %w[user_message agent_message].freeze

      ROLE_MAP = {
        "user_message" => "user",
        "agent_message" => "assistant"
      }.freeze

      attr_reader :messages

      def initialize
        @messages = []
      end

      def emit(event)
        type = event.dig(:payload, :type)
        return unless DISPLAYABLE_TYPES.include?(type)

        @messages << {
          role: ROLE_MAP.fetch(type),
          content: event.dig(:payload, :content)
        }
      end

      def clear
        @messages = []
      end
    end
  end
end
