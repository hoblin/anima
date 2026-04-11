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
  has_many :sub_goals, -> { order(:created_at) }, class_name: "Goal", foreign_key: :parent_goal_id, dependent: :destroy
  has_many :goal_pinned_messages, dependent: :destroy
  has_many :pinned_messages, through: :goal_pinned_messages

  validates :description, presence: true
  validates :status, inclusion: {in: STATUSES}
  validate :parent_goal_belongs_to_same_session, if: :parent_goal
  validate :parent_goal_is_root, if: :parent_goal

  scope :active, -> { where(status: "active") }
  scope :completed, -> { where(status: "completed") }
  scope :root, -> { where(parent_goal_id: nil) }

  # @!method self.not_evicted
  #   Goals still visible in context (not yet evicted by the analytical brain).
  #   @return [ActiveRecord::Relation]
  scope :not_evicted, -> { where(evicted_at: nil) }

  # @!method self.evictable
  #   Completed goals not yet evicted — their phantom pairs remain in the
  #   sliding window until Mneme compresses them during the eviction cycle.
  #   @return [ActiveRecord::Relation]
  scope :evictable, -> { completed.where(evicted_at: nil) }

  after_commit :broadcast_goals_update
  after_commit :schedule_passive_recall, on: [:create, :update]

  # @return [Boolean] true if this goal has been completed
  def completed? = status == "completed"

  # @return [Boolean] true if this goal is still active
  def active? = status == "active"

  # @return [Boolean] true if this is a root goal (no parent)
  def root? = !parent_goal_id

  # @return [Boolean] true if this goal has been evicted from display
  def evicted? = evicted_at.present?

  # Cascades completion to all active sub-goals. Called when a root goal
  # is finished — remaining sub-items are implicitly resolved because
  # the semantic episode that spawned them has ended.
  #
  # Uses +update_all+ to avoid N per-record +after_commit+ broadcasts;
  # the caller ({Melete::Tools::FinishGoal}) wraps the whole
  # operation in a transaction so the root goal's single broadcast
  # includes the cascaded state.
  #
  # @return [void]
  def cascade_completion!
    now = Time.current
    sub_goals.active.update_all(status: "completed", completed_at: now, updated_at: now)
  end

  # Releases pinned messages that have no remaining active Goal references
  # anywhere in the session. Called after goal (and cascade) completion —
  # the orphaned scope checks all Goals, so pins shared with other active
  # Goals survive automatically via reference counting.
  #
  # @return [Integer] number of released pins
  def release_orphaned_pins!
    orphaned = session.pinned_messages.orphaned
    orphaned.destroy_all.size
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
      "sub_goals" => sub_goals.map { |sub|
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

  # Triggers passive recall when goals change so relevant memories
  # surface in the viewport automatically.
  #
  # @return [void]
  def schedule_passive_recall
    return if session.sub_agent?

    PassiveRecallJob.perform_later(session_id)
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
