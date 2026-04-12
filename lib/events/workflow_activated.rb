# frozen_string_literal: true

module Events
  # Emitted after {Session#activate_workflow} enqueues a workflow's
  # phantom pair. Subscribers rebroadcast the session's active
  # skills/workflow so the HUD reflects the new activation.
  class WorkflowActivated
    TYPE = "workflow.activated"

    attr_reader :session_id, :workflow_name

    # @param session_id [Integer] the session the workflow was activated on
    # @param workflow_name [String] canonical workflow name
    def initialize(session_id:, workflow_name:)
      @session_id = session_id
      @workflow_name = workflow_name
    end

    def event_name
      "#{Bus::NAMESPACE}.#{TYPE}"
    end

    def to_h
      {type: TYPE, session_id:, workflow_name:}
    end
  end
end
