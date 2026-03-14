# frozen_string_literal: true

module Events
  # Emitted in the parent session when a sub-agent finishes its task
  # via {Tools::ReturnResult}. Carries the deliverable back to the
  # parent agent's conversation stream.
  class SubagentCompleted < Base
    TYPE = "subagent_completed"

    # @return [Integer] session ID of the sub-agent that completed
    attr_reader :child_session_id

    # @return [String] original task assigned to the sub-agent
    attr_reader :task

    # @return [String] expected deliverable description
    attr_reader :expected_output

    # @param content [String] the sub-agent's result
    # @param child_session_id [Integer] ID of the child session
    # @param task [String] original task text
    # @param expected_output [String] expected deliverable description
    # @param session_id [Integer, nil] parent session ID
    def initialize(content:, child_session_id:, task:, expected_output:, session_id: nil)
      super(content: content, session_id: session_id)
      @child_session_id = child_session_id
      @task = task
      @expected_output = expected_output
    end

    def type
      TYPE
    end

    def to_h
      super.merge(
        child_session_id: child_session_id,
        task: task,
        expected_output: expected_output
      )
    end
  end
end
