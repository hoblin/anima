# frozen_string_literal: true

module Events
  # Emitted after {Session#activate_skill} enqueues a skill's phantom
  # pair. Subscribers rebroadcast the session's active skills/workflow
  # so the HUD reflects the new activation immediately (before the
  # pending message even promotes).
  class SkillActivated
    TYPE = "skill.activated"

    attr_reader :session_id, :skill_name

    # @param session_id [Integer] the session the skill was activated on
    # @param skill_name [String] canonical skill name
    def initialize(session_id:, skill_name:)
      @session_id = session_id
      @skill_name = skill_name
    end

    def event_name
      "#{Bus::NAMESPACE}.#{TYPE}"
    end

    def to_h
      {type: TYPE, session_id:, skill_name:}
    end
  end
end
