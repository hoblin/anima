# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentMessageDecorator, type: :decorator do
  let(:session) { Session.create! }

  describe "#render_basic" do
    it "returns the agent message with 'Anima:' prefix" do
      event = session.events.create!(event_type: "agent_message", payload: {"content" => "I can help"}, timestamp: 1)
      decorator = EventDecorator.for(event)

      expect(decorator.render_basic).to eq(["Anima: I can help"])
    end

    it "handles multiline content" do
      event = session.events.create!(event_type: "agent_message", payload: {"content" => "line 1\nline 2"}, timestamp: 1)
      decorator = EventDecorator.for(event)

      expect(decorator.render_basic).to eq(["Anima: line 1\nline 2"])
    end

    it "works with hash payloads" do
      decorator = EventDecorator.for(type: "agent_message", content: "from hash")

      expect(decorator.render_basic).to eq(["Anima: from hash"])
    end
  end

  describe "#render_verbose" do
    it "prepends timestamp to the agent message" do
      ts = 1_709_312_325_000_000_000
      event = session.events.create!(event_type: "agent_message", payload: {"content" => "I can help"}, timestamp: ts)
      decorator = EventDecorator.for(event)
      expected_time = Time.at(ts / 1_000_000_000.0).strftime("%H:%M:%S")

      expect(decorator.render_verbose).to eq(["[#{expected_time}] Anima: I can help"])
    end

    it "handles multiline content" do
      ts = 1_709_312_325_000_000_000
      event = session.events.create!(event_type: "agent_message", payload: {"content" => "line 1\nline 2"}, timestamp: ts)
      decorator = EventDecorator.for(event)
      expected_time = Time.at(ts / 1_000_000_000.0).strftime("%H:%M:%S")

      expect(decorator.render_verbose).to eq(["[#{expected_time}] Anima: line 1\nline 2"])
    end

    it "shows placeholder when timestamp is nil" do
      decorator = EventDecorator.for(type: "agent_message", content: "no timestamp")

      expect(decorator.render_verbose).to eq(["[--:--:--] Anima: no timestamp"])
    end
  end
end
