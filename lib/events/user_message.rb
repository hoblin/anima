# frozen_string_literal: true

module Events
  class UserMessage < Base
    TYPE = "user_message"

    # @param content [String] message text
    # @param session_id [Integer, nil] session identifier
    def initialize(content:, session_id: nil)
      super
    end

    def type
      TYPE
    end
  end
end
