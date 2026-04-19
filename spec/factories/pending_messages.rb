# frozen_string_literal: true

FactoryBot.define do
  factory :pending_message do
    session
    content { "pending content" }
    source_type { "user" }
    message_type { "user_message" }

    trait :subagent do
      source_type { "subagent" }
      source_name { "loop-sleuth" }
      message_type { "subagent" }
    end

    trait :tool_response do
      source_type { "tool" }
      source_name { "bash" }
      message_type { "tool_response" }
      sequence(:tool_use_id) { |n| "toolu_#{n}" }
      success { true }
    end

    trait :from_mneme do
      source_type { "recall" }
      sequence(:source_name) { |n| n.to_s }
      message_type { "from_mneme" }
    end

    trait :from_melete_skill do
      source_type { "skill" }
      source_name { "gh-issue" }
      message_type { "from_melete_skill" }
    end

    trait :from_melete_workflow do
      source_type { "workflow" }
      source_name { "feature" }
      message_type { "from_melete_workflow" }
    end

    trait :from_melete_goal do
      source_type { "goal" }
      sequence(:source_name) { |n| n.to_s }
      message_type { "from_melete_goal" }
    end

    trait :bounce_back do
      bounce_back { true }
    end
  end
end
