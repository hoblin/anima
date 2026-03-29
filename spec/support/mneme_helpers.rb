# frozen_string_literal: true

# Shared helpers for Mneme specs. Provides a consistent `create_event`
# factory that builds events with predetermined token counts for
# deterministic viewport tests.
module MnemeHelpers
  # Creates an event on the given session with a predetermined token count.
  #
  # @param session [Session] the session to attach the event to
  # @param type [String] event type (user_message, agent_message, tool_call, etc.)
  # @param content [String] message content or tool response content
  # @param token_count [Integer] predetermined token count
  # @param tool_name [String, nil] tool name for tool_call/tool_response events
  # @param tool_input [Hash, nil] tool input for tool_call events
  # @return [Event] the created event
  def create_mneme_event(session, type:, content: "msg", token_count: 100, tool_name: nil, tool_input: nil)
    payload = case type
    when "tool_call"
      {"content" => "Calling #{tool_name}", "tool_name" => tool_name,
       "tool_input" => tool_input || {}, "tool_use_id" => "tu_#{SecureRandom.hex(4)}"}
    when "tool_response"
      {"content" => content, "tool_name" => tool_name, "tool_use_id" => "tu_#{SecureRandom.hex(4)}"}
    else
      {"content" => content}
    end

    session.events.create!(
      event_type: type,
      payload: payload,
      tool_use_id: payload["tool_use_id"],
      timestamp: Time.current.to_ns,
      token_count: token_count
    )
  end
end

RSpec.configure do |config|
  config.include MnemeHelpers
end
