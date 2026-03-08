# frozen_string_literal: true

module Events
  class UserMessage < Base
    TYPE = "user_message"

    def type
      TYPE
    end
  end
end
