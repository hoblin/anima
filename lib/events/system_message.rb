# frozen_string_literal: true

module Events
  class SystemMessage < Base
    TYPE = "system_message"

    def type
      TYPE
    end
  end
end
