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
  end
end
