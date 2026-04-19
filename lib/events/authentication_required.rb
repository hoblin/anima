# frozen_string_literal: true

module Events
  # Emitted when the Anthropic provider rejects the configured token with
  # an authentication error. Surfaces to the TUI via
  # {Events::Subscribers::AuthenticationBroadcaster} so the user is
  # prompted for a new token — and to the conversation as a system
  # message so the failure is visible in history.
  #
  # Not persisted — not included in {Message::TYPES}.
  class AuthenticationRequired < Base
    TYPE = "authentication_required"

    # @param session_id [Integer] session the failure is scoped to
    # @param content [String] human-readable error text from the provider
    def initialize(session_id:, content:)
      super(content: content, session_id: session_id)
    end

    def type
      TYPE
    end
  end
end
