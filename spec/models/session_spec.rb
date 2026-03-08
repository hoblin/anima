# frozen_string_literal: true

require "rails_helper"

RSpec.describe Session do
  describe "associations" do
    it "has many events ordered by id" do
      session = Session.create!
      event_a = session.events.create!(event_type: "user_message", payload: {content: "first"}, timestamp: 1)
      event_b = session.events.create!(event_type: "user_message", payload: {content: "second"}, timestamp: 2)

      expect(session.events.reload).to eq([event_a, event_b])
    end

    it "destroys events when session is destroyed" do
      session = Session.create!
      session.events.create!(event_type: "user_message", payload: {content: "hi"}, timestamp: 1)

      expect { session.destroy }.to change(Event, :count).by(-1)
    end
  end

  describe "#messages_for_llm" do
    let(:session) { Session.create! }

    it "returns user_message events with user role" do
      session.events.create!(event_type: "user_message", payload: {"content" => "hello"}, timestamp: 1)

      expect(session.messages_for_llm).to eq([{role: "user", content: "hello"}])
    end

    it "returns agent_message events with assistant role" do
      session.events.create!(event_type: "agent_message", payload: {"content" => "hi there"}, timestamp: 1)

      expect(session.messages_for_llm).to eq([{role: "assistant", content: "hi there"}])
    end

    it "excludes system_message events" do
      session.events.create!(event_type: "system_message", payload: {"content" => "boot"}, timestamp: 1)

      expect(session.messages_for_llm).to be_empty
    end

    context "with tool events" do
      it "assembles tool_call events as assistant messages with tool_use blocks" do
        session.events.create!(
          event_type: "tool_call",
          payload: {"content" => "Calling web_get", "tool_name" => "web_get",
                    "tool_input" => {"url" => "https://example.com"}, "tool_use_id" => "toolu_123"},
          timestamp: 1
        )

        result = session.messages_for_llm
        expect(result).to eq([
          {role: "assistant", content: [
            {type: "tool_use", id: "toolu_123", name: "web_get", input: {"url" => "https://example.com"}}
          ]}
        ])
      end

      it "assembles tool_response events as user messages with tool_result blocks" do
        session.events.create!(
          event_type: "tool_response",
          payload: {"content" => "<html>hello</html>", "tool_name" => "web_get",
                    "tool_use_id" => "toolu_123", "success" => true},
          timestamp: 1
        )

        result = session.messages_for_llm
        expect(result).to eq([
          {role: "user", content: [
            {type: "tool_result", tool_use_id: "toolu_123", content: "<html>hello</html>"}
          ]}
        ])
      end

      it "groups consecutive tool_call events into one assistant message" do
        session.events.create!(
          event_type: "tool_call",
          payload: {"content" => "Calling web_get", "tool_name" => "web_get",
                    "tool_input" => {"url" => "https://a.com"}, "tool_use_id" => "toolu_1"},
          timestamp: 1
        )
        session.events.create!(
          event_type: "tool_call",
          payload: {"content" => "Calling web_get", "tool_name" => "web_get",
                    "tool_input" => {"url" => "https://b.com"}, "tool_use_id" => "toolu_2"},
          timestamp: 2
        )

        result = session.messages_for_llm
        expect(result.length).to eq(1)
        expect(result.first[:role]).to eq("assistant")
        expect(result.first[:content].length).to eq(2)
      end

      it "groups consecutive tool_response events into one user message" do
        session.events.create!(
          event_type: "tool_response",
          payload: {"content" => "page A", "tool_name" => "web_get", "tool_use_id" => "toolu_1"},
          timestamp: 1
        )
        session.events.create!(
          event_type: "tool_response",
          payload: {"content" => "page B", "tool_name" => "web_get", "tool_use_id" => "toolu_2"},
          timestamp: 2
        )

        result = session.messages_for_llm
        expect(result.length).to eq(1)
        expect(result.first[:role]).to eq("user")
        expect(result.first[:content].length).to eq(2)
      end

      it "assembles a full tool conversation correctly" do
        session.events.create!(event_type: "user_message", payload: {"content" => "what is on example.com?"}, timestamp: 1)
        session.events.create!(
          event_type: "tool_call",
          payload: {"content" => "Calling web_get", "tool_name" => "web_get",
                    "tool_input" => {"url" => "https://example.com"}, "tool_use_id" => "toolu_abc"},
          timestamp: 2
        )
        session.events.create!(
          event_type: "tool_response",
          payload: {"content" => "<html>Example Domain</html>", "tool_name" => "web_get",
                    "tool_use_id" => "toolu_abc", "success" => true},
          timestamp: 3
        )
        session.events.create!(event_type: "agent_message", payload: {"content" => "The page says Example Domain."}, timestamp: 4)

        result = session.messages_for_llm
        expect(result).to eq([
          {role: "user", content: "what is on example.com?"},
          {role: "assistant", content: [
            {type: "tool_use", id: "toolu_abc", name: "web_get", input: {"url" => "https://example.com"}}
          ]},
          {role: "user", content: [
            {type: "tool_result", tool_use_id: "toolu_abc", content: "<html>Example Domain</html>"}
          ]},
          {role: "assistant", content: "The page says Example Domain."}
        ])
      end
    end

    it "preserves event order" do
      session.events.create!(event_type: "user_message", payload: {"content" => "first"}, timestamp: 1)
      session.events.create!(event_type: "agent_message", payload: {"content" => "second"}, timestamp: 2)
      session.events.create!(event_type: "user_message", payload: {"content" => "third"}, timestamp: 3)

      expect(session.messages_for_llm).to eq([
        {role: "user", content: "first"},
        {role: "assistant", content: "second"},
        {role: "user", content: "third"}
      ])
    end

    context "with token budget" do
      it "includes all events when within budget" do
        session.events.create!(event_type: "user_message", payload: {"content" => "hi"}, timestamp: 1, token_count: 10)
        session.events.create!(event_type: "agent_message", payload: {"content" => "hello"}, timestamp: 2, token_count: 10)

        expect(session.messages_for_llm(token_budget: 100)).to eq([
          {role: "user", content: "hi"},
          {role: "assistant", content: "hello"}
        ])
      end

      it "drops oldest events when budget exceeded" do
        session.events.create!(event_type: "user_message", payload: {"content" => "old"}, timestamp: 1, token_count: 50)
        session.events.create!(event_type: "agent_message", payload: {"content" => "old reply"}, timestamp: 2, token_count: 50)
        session.events.create!(event_type: "user_message", payload: {"content" => "recent"}, timestamp: 3, token_count: 50)
        session.events.create!(event_type: "agent_message", payload: {"content" => "recent reply"}, timestamp: 4, token_count: 50)

        result = session.messages_for_llm(token_budget: 100)

        expect(result).to eq([
          {role: "user", content: "recent"},
          {role: "assistant", content: "recent reply"}
        ])
      end

      it "always includes at least the newest event even if it exceeds budget" do
        session.events.create!(event_type: "user_message", payload: {"content" => "big message"}, timestamp: 1, token_count: 500)

        result = session.messages_for_llm(token_budget: 100)

        expect(result).to eq([{role: "user", content: "big message"}])
      end

      it "uses heuristic estimate for events with zero token_count" do
        session.events.create!(event_type: "user_message", payload: {"content" => "x" * 400}, timestamp: 1, token_count: 0)
        session.events.create!(event_type: "user_message", payload: {"content" => "recent"}, timestamp: 2, token_count: 10)

        # "x" * 400 => ~100 token estimate, plus 10 = 110, fits in 200
        result = session.messages_for_llm(token_budget: 200)
        expect(result.length).to eq(2)
      end

      it "returns events in chronological order" do
        session.events.create!(event_type: "user_message", payload: {"content" => "first"}, timestamp: 1, token_count: 10)
        session.events.create!(event_type: "agent_message", payload: {"content" => "second"}, timestamp: 2, token_count: 10)
        session.events.create!(event_type: "user_message", payload: {"content" => "third"}, timestamp: 3, token_count: 10)

        result = session.messages_for_llm(token_budget: 30)

        expect(result.map { |m| m[:content] }).to eq(%w[first second third])
      end
    end
  end
end
