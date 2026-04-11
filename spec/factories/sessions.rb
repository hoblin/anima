# frozen_string_literal: true

FactoryBot.define do
  factory :session do
    trait :sub_agent do
      association :parent_session, factory: :session
      prompt { "You are a focused sub-agent." }
    end
  end
end
