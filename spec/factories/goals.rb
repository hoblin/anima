# frozen_string_literal: true

FactoryBot.define do
  factory :goal do
    session
    sequence(:description) { |n| "Goal ##{n}" }

    trait :completed do
      status { "completed" }
      completed_at { Time.current }
    end

    trait :evicted do
      status { "completed" }
      completed_at { 2.hours.ago }
      evicted_at { 1.hour.ago }
    end
  end
end
