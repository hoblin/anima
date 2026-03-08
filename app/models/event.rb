# frozen_string_literal: true

class Event < ApplicationRecord
  belongs_to :session

  validates :event_type, presence: true
  validates :payload, presence: true
  validates :position, presence: true, numericality: {only_integer: true, greater_than_or_equal_to: 0}
  validates :timestamp, presence: true

  before_validation :assign_position, on: :create

  private

  def assign_position
    return if position.present?

    max = self.class.where(session_id: session_id).maximum(:position)
    self.position = max ? max + 1 : 0
  end
end
