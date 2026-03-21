# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::ReturnResult do
  let(:parent_session) { Session.create! }
  let(:child_session) do
    Session.create!(
      parent_session: parent_session,
      prompt: "You are a focused sub-agent.\n\nExpected deliverable: A summary of tool dispatch"
    )
  end
  let(:persister) { Events::Subscribers::Persister.new }

  subject(:tool) { described_class.new(session: child_session) }

  before do
    Events::Bus.subscribe(persister)
    # Simulate the task user_message that spawn_subagent persists via create_user_event
    child_session.events.create!(
      event_type: "user_message",
      payload: {"content" => "Read lib/agent_loop.rb and summarize the tool execution flow"},
      timestamp: 1
    )
  end

  after { Events::Bus.unsubscribe(persister) }

  describe ".tool_name" do
    it "returns return_result" do
      expect(described_class.tool_name).to eq("return_result")
    end
  end

  describe ".description" do
    it "returns a non-empty description" do
      expect(described_class.description).to be_a(String)
      expect(described_class.description).not_to be_empty
    end
  end

  describe ".input_schema" do
    it "defines result as a required string property" do
      schema = described_class.input_schema
      expect(schema[:type]).to eq("object")
      expect(schema[:properties][:result][:type]).to eq("string")
      expect(schema[:required]).to eq(["result"])
    end
  end

  describe ".schema" do
    it "builds valid Anthropic tool schema" do
      schema = described_class.schema
      expect(schema).to include(name: "return_result", description: a_kind_of(String))
      expect(schema[:input_schema]).to be_a(Hash)
    end
  end

  describe "#execute" do
    let(:input) { {"result" => "The tool execution flow works as follows: ..."} }

    it "creates a tool_call event in the parent session" do
      tool.execute(input)

      event = parent_session.events.find_by(event_type: "tool_call")
      expect(event).to be_present
      expect(event.payload["tool_name"]).to eq("spawn_subagent")
      expect(event.payload["tool_input"]["task"]).to eq("Read lib/agent_loop.rb and summarize the tool execution flow")
      expect(event.payload["tool_input"]["session_id"]).to eq(child_session.id)
    end

    it "creates a tool_response event in the parent session with the result" do
      tool.execute(input)

      event = parent_session.events.find_by(event_type: "tool_response")
      expect(event).to be_present
      expect(event.payload["content"]).to eq("The tool execution flow works as follows: ...")
      expect(event.payload["tool_name"]).to eq("spawn_subagent")
    end

    it "correlates tool_call and tool_response with matching tool_use_id" do
      tool.execute(input)

      call = parent_session.events.find_by(event_type: "tool_call")
      response = parent_session.events.find_by(event_type: "tool_response")

      expect(call.payload["tool_use_id"]).to eq(response.payload["tool_use_id"])
      expect(call.payload["tool_use_id"]).to eq("toolu_subagent_#{child_session.id}")
    end

    it "returns confirmation message" do
      result = tool.execute(input)
      expect(result).to include("Result delivered to parent session #{parent_session.id}")
    end

    context "with blank result" do
      it "returns error" do
        result = tool.execute("result" => "  ")
        expect(result).to eq({error: "Result cannot be blank"})
      end

      it "does not create events in the parent session" do
        tool.execute("result" => "")
        expect(parent_session.events.where(event_type: %w[tool_call tool_response])).to be_empty
      end
    end

    context "from a named specialist session" do
      let(:specialist_session) do
        Session.create!(
          parent_session: parent_session,
          prompt: "You are a code analyst.\n\nExpected deliverable: analysis",
          name: "analyzer"
        )
      end

      subject(:tool) { described_class.new(session: specialist_session) }

      before do
        specialist_session.events.create!(
          event_type: "user_message",
          payload: {"content" => "Analyze the codebase"},
          timestamp: 1
        )
      end

      it "uses spawn_specialist as the tool_name in events" do
        tool.execute(input)

        call = parent_session.events.find_by(event_type: "tool_call")
        response = parent_session.events.find_by(event_type: "tool_response")

        expect(call.payload["tool_name"]).to eq("spawn_specialist")
        expect(response.payload["tool_name"]).to eq("spawn_specialist")
      end
    end

    context "when called from a main session (no parent)" do
      let(:main_session) { Session.create! }

      subject(:tool) { described_class.new(session: main_session) }

      it "returns error" do
        result = tool.execute("result" => "some result")
        expect(result).to eq({error: "No parent session — only sub-agents can return results"})
      end
    end
  end
end
