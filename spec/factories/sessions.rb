# frozen_string_literal: true

FactoryBot.define do
  factory :session do
    trait :sub_agent do
      association :parent_session, factory: :session
      prompt { "You are a focused sub-agent." }
    end

    trait :awaiting do
      after(:create) { |session| session.start_processing! }
    end

    trait :executing do
      after(:create) do |session|
        session.start_processing!
        session.tool_received!
      end
    end
  end
end
