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

    it "excludes system_message, tool_call, and tool_response events" do
      session.events.create!(event_type: "system_message", payload: {"content" => "boot"}, timestamp: 1)
      session.events.create!(event_type: "tool_call", payload: {"content" => "run"}, timestamp: 2)
      session.events.create!(event_type: "tool_response", payload: {"content" => "ok"}, timestamp: 3)

      expect(session.messages_for_llm).to be_empty
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
