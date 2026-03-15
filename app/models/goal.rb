# frozen_string_literal: true

# A persistent objective tracked by the analytical brain during a session.
# Goals form a two-level hierarchy: root goals represent high-level
# objectives (semantic episodes), while sub-goals are TODO-style steps
# rendered as checklist items in the agent's system prompt.
#
# The analytical brain creates and completes goals; the main agent sees
# them in its context window but never manages them directly.
class Goal < ApplicationRecord
  STATUSES = %w[active completed].freeze

  belongs_to :session
  belongs_to :parent_goal, class_name: "Goal", optional: true
  has_many :sub_goals, class_name: "Goal", foreign_key: :parent_goal_id, dependent: :destroy

  validates :description, presence: true
  validates :status, inclusion: {in: STATUSES}
  validate :parent_goal_belongs_to_same_session, if: :parent_goal
  validate :parent_goal_is_root, if: :parent_goal

  scope :active, -> { where(status: "active") }
  scope :completed, -> { where(status: "completed") }
  scope :root, -> { where(parent_goal_id: nil) }

  after_commit :broadcast_goals_update

  # @return [Boolean] true if this goal has been completed
  def completed? = status == "completed"

  # @return [Boolean] true if this is a root goal (no parent)
  def root? = !parent_goal_id

  # Cascades completion to all active sub-goals. Called when a root goal
  # is finished — remaining sub-items are implicitly resolved.
  #
  # @return [void]
  def cascade_completion!
    sub_goals.active.find_each do |sub|
      sub.update!(status: "completed", completed_at: Time.current)
    end
  end

  # Serializes this goal for ActionCable broadcast and TUI display.
  # Includes nested sub-goals for root goals.
  #
  # @return [Hash{String => Object}] with keys "id", "description", "status",
  #   and "sub_goals" (Array of Hash with "id", "description", "status")
  def as_summary
    {
      "id" => id,
      "description" => description,
      "status" => status,
      "sub_goals" => sub_goals.sort_by(&:created_at).map { |sub|
        {"id" => sub.id, "description" => sub.description, "status" => sub.status}
      }
    }
  end

  private

  def parent_goal_belongs_to_same_session
    return if parent_goal.session_id == session_id

    errors.add(:parent_goal, "must belong to the same session")
  end

  def parent_goal_is_root
    return unless parent_goal.parent_goal_id

    errors.add(:parent_goal, "cannot nest deeper than two levels")
  end

  # Broadcasts goal changes to all clients subscribed to this session.
  # Mirrors the Session#broadcast_active_skills_update pattern so the
  # TUI info panel updates reactively.
  #
  # @return [void]
  def broadcast_goals_update
    ActionCable.server.broadcast("session_#{session_id}", {
      "action" => "goals_updated",
      "session_id" => session_id,
      "goals" => session.goals_summary
    })
  end
end
