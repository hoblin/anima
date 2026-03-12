# frozen_string_literal: true

require "rails_helper"

RSpec.describe UserMessageDecorator do
  let(:session) { Session.create! }

  describe "#render_basic" do
    it "returns the user message with 'You:' prefix" do
      event = session.events.create!(event_type: "user_message", payload: {"content" => "hello world"}, timestamp: 1)
      decorator = EventDecorator.for(event)

      expect(decorator.render_basic).to eq(["You: hello world"])
    end

    it "handles multiline content" do
      event = session.events.create!(event_type: "user_message", payload: {"content" => "line 1\nline 2"}, timestamp: 1)
      decorator = EventDecorator.for(event)

      expect(decorator.render_basic).to eq(["You: line 1\nline 2"])
    end

    it "works with hash payloads (symbol keys)" do
      decorator = EventDecorator.for(type: "user_message", content: "from hash")

      expect(decorator.render_basic).to eq(["You: from hash"])
    end

    it "works with hash payloads (string keys)" do
      decorator = EventDecorator.for("type" => "user_message", "content" => "from string hash")

      expect(decorator.render_basic).to eq(["You: from string hash"])
    end
  end
end
