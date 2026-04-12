# frozen_string_literal: true

FactoryBot.define do
  factory :message do
    session
    payload { {"content" => "msg"} }
    timestamp { Time.current.to_ns }

    trait :user_message do
      message_type { "user_message" }
    end

    trait :agent_message do
      message_type { "agent_message" }
    end

    trait :system_message do
      message_type { "system_message" }
    end

    trait :think_tool_call do
      message_type { "tool_call" }
      payload { {"tool_name" => "think", "tool_input" => {"thoughts" => "..."}} }
      sequence(:tool_use_id) { |n| "tu_think_#{n}" }
    end

    trait :bash_tool_call do
      message_type { "tool_call" }
      payload { {"tool_name" => "bash", "tool_input" => {"command" => "ls"}} }
      sequence(:tool_use_id) { |n| "tu_bash_#{n}" }
    end

    trait :bash_tool_response do
      message_type { "tool_response" }
      payload { {"content" => "ok", "tool_name" => "bash"} }
      sequence(:tool_use_id) { |n| "tu_bash_resp_#{n}" }
    end

    trait :tool_call do
      message_type { "tool_call" }
      sequence(:tool_use_id) { |n| "tu_call_#{n}" }
    end

    trait :tool_response do
      message_type { "tool_response" }
      sequence(:tool_use_id) { |n| "tu_resp_#{n}" }
    end

    trait :from_melete_skill do
      message_type { "tool_call" }
      transient { skill_name { "gh-issue" } }
      sequence(:tool_use_id) { |n| "from_melete_skill_#{n}" }
      payload do
        {"tool_name" => PendingMessage::MELETE_SKILL_TOOL,
         "tool_input" => {"skill" => skill_name},
         "tool_use_id" => tool_use_id,
         "content" => "[recalled skill: #{skill_name}]"}
      end
    end

    trait :from_melete_workflow do
      message_type { "tool_call" }
      transient { workflow_name { "feature" } }
      sequence(:tool_use_id) { |n| "from_melete_workflow_#{n}" }
      payload do
        {"tool_name" => PendingMessage::MELETE_WORKFLOW_TOOL,
         "tool_input" => {"workflow" => workflow_name},
         "tool_use_id" => tool_use_id,
         "content" => "[recalled workflow: #{workflow_name}]"}
      end
    end
  end
end
