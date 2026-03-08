# frozen_string_literal: true

module Events
  class AgentMessage < Base
    TYPE = "agent_message"

    def type
      TYPE
    end
  end
end
