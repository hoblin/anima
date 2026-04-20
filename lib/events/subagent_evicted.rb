# frozen_string_literal: true

module Events
  # Emitted when {Mneme::Runner} advances the boundary past every remaining
  # trace of a sub-agent — the spawn pair plus every +from_{nickname}+
  # phantom pair. Subscribers broadcast the removal so clients drop the
  # entry from the HUD panel.
  #
  # +session_id+ is the parent session (HUD owner), +child_id+ is the
  # sub-agent session whose traces just aged out.
  class SubagentEvicted
    TYPE = "subagent.evicted"

    attr_reader :session_id, :child_id

    # @param session_id [Integer] parent session whose HUD should drop the entry
    # @param child_id [Integer] sub-agent session whose traces were evicted
    def initialize(session_id:, child_id:)
      @session_id = session_id
      @child_id = child_id
    end

    def event_name
      "#{Bus::NAMESPACE}.#{TYPE}"
    end

    def to_h
      {type: TYPE, session_id:, child_id:}
    end
  end
end
