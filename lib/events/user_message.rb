# frozen_string_literal: true

module Events
  class UserMessage < Base
    TYPE = "user_message"

    # @return [String, nil] "pending" when queued during active processing, nil otherwise
    attr_reader :status

    # @param content [String] message text
    # @param session_id [Integer, nil] session identifier
    # @param status [String, nil] "pending" when queued during active agent processing
    def initialize(content:, session_id: nil, status: nil)
      super(content: content, session_id: session_id)
      @status = status
    end

    def type
      TYPE
    end

    def to_h
      h = super
      h[:status] = status if status
      h
    end
  end
end
