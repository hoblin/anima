# frozen_string_literal: true

require "rails_helper"

RSpec.describe UserMessageDecorator, type: :decorator do
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

  describe "#render_verbose" do
    it "prepends timestamp to the user message" do
      ts = 1_709_312_325_000_000_000
      event = session.events.create!(event_type: "user_message", payload: {"content" => "hello"}, timestamp: ts)
      decorator = EventDecorator.for(event)
      expected_time = Time.at(ts / 1_000_000_000.0).strftime("%H:%M:%S")

      expect(decorator.render_verbose).to eq(["[#{expected_time}] You: hello"])
    end

    it "handles multiline content" do
      ts = 1_709_312_325_000_000_000
      event = session.events.create!(event_type: "user_message", payload: {"content" => "line 1\nline 2"}, timestamp: ts)
      decorator = EventDecorator.for(event)
      expected_time = Time.at(ts / 1_000_000_000.0).strftime("%H:%M:%S")

      expect(decorator.render_verbose).to eq(["[#{expected_time}] You: line 1\nline 2"])
    end

    it "shows placeholder when timestamp is nil" do
      decorator = EventDecorator.for(type: "user_message", content: "no timestamp")

      expect(decorator.render_verbose).to eq(["[--:--:--] You: no timestamp"])
    end
  end
end
