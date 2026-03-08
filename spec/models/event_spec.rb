# frozen_string_literal: true

require "rails_helper"

RSpec.describe Event do
  let(:session) { Session.create! }

  describe "validations" do
    it "requires event_type" do
      event = Event.new(session: session, payload: {content: "hi"}, timestamp: 1)
      event.event_type = nil
      expect(event).not_to be_valid
      expect(event.errors[:event_type]).to include("can't be blank")
    end

    it "rejects invalid event_type" do
      event = Event.new(session: session, event_type: "invalid", payload: {content: "hi"}, timestamp: 1)
      expect(event).not_to be_valid
      expect(event.errors[:event_type]).to include("is not included in the list")
    end

    it "requires payload" do
      event = Event.new(session: session, event_type: "user_message", timestamp: 1)
      event.payload = nil
      expect(event).not_to be_valid
      expect(event.errors[:payload]).to include("can't be blank")
    end

    it "requires timestamp" do
      event = Event.new(session: session, event_type: "user_message", payload: {content: "hi"})
      event.timestamp = nil
      expect(event).not_to be_valid
      expect(event.errors[:timestamp]).to include("can't be blank")
    end

    it "requires session" do
      event = Event.new(event_type: "user_message", payload: {content: "hi"}, timestamp: 1)
      expect(event).not_to be_valid
    end

    it "is valid with all required attributes" do
      event = Event.new(session: session, event_type: "user_message", payload: {content: "hi"}, timestamp: 1)
      expect(event).to be_valid
    end
  end

  describe ".llm_messages" do
    it "returns only user_message and agent_message events" do
      session.events.create!(event_type: "user_message", payload: {content: "hi"}, timestamp: 1)
      session.events.create!(event_type: "agent_message", payload: {content: "hello"}, timestamp: 2)
      session.events.create!(event_type: "system_message", payload: {content: "boot"}, timestamp: 3)
      session.events.create!(event_type: "tool_call", payload: {content: "run", tool_name: "bash", tool_input: {}}, timestamp: 4)

      expect(Event.llm_messages.pluck(:event_type)).to match_array(%w[user_message agent_message])
    end
  end

  describe "associations" do
    it "belongs to a session" do
      event = session.events.create!(event_type: "user_message", payload: {content: "hi"}, timestamp: 1)
      expect(event.session).to eq(session)
    end
  end
end
