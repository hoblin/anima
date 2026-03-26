# frozen_string_literal: true

# A conversation message pinned to one or more Goals by Mneme to protect it
# from viewport eviction. Pinned messages appear in the Goals section of
# the viewport, giving the main agent access to critical context that
# would otherwise scroll out of the sliding window.
#
# Pinning is goal-scoped: when all Goals referencing a pin complete,
# the pin is automatically released (reference-counted cleanup).
#
# @!attribute display_text
#   @return [String] truncated message content (~200 chars) shown in the Goals section
class PinnedMessage < ApplicationRecord
  # Display text limit — enough to recognize content, cheap on tokens.
  MAX_DISPLAY_TEXT_LENGTH = 200

  belongs_to :message

  has_many :goal_pinned_messages, dependent: :destroy
  has_many :goals, through: :goal_pinned_messages

  validates :display_text, presence: true, length: {maximum: MAX_DISPLAY_TEXT_LENGTH}
  validates :message_id, uniqueness: true

  # Pinned messages with no remaining active goals — safe to release.
  #
  # @return [ActiveRecord::Relation]
  scope :orphaned, -> {
    where.not(
      "EXISTS (SELECT 1 FROM goal_pinned_messages gpm " \
      "JOIN goals ON goals.id = gpm.goal_id " \
      "WHERE gpm.pinned_message_id = pinned_messages.id " \
      "AND goals.status = 'active')"
    )
  }

  # @return [Integer] token cost estimate for viewport budget accounting
  def token_cost
    [(display_text.bytesize / Message::BYTES_PER_TOKEN.to_f).ceil, 1].max
  end
end
