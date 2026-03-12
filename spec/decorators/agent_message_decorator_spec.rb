# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentMessageDecorator do
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
end
