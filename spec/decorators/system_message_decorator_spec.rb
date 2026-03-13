# frozen_string_literal: true

require "rails_helper"

RSpec.describe SystemMessageDecorator, type: :decorator do
  let(:session) { Session.create! }

  describe "#render_basic" do
    it "returns nil (hidden in basic mode)" do
      event = session.events.create!(
        event_type: "system_message",
        payload: {"content" => "retrying..."},
        timestamp: 1
      )
      decorator = EventDecorator.for(event)

      expect(decorator.render_basic).to be_nil
    end

    it "returns nil for hash payloads" do
      decorator = EventDecorator.for(type: "system_message", content: "internal")

      expect(decorator.render_basic).to be_nil
    end
  end

  describe "#render_verbose" do
    it "shows timestamped system message" do
      ts = 1_709_312_325_000_000_000
      event = session.events.create!(
        event_type: "system_message",
        payload: {"content" => "retrying after error"},
        timestamp: ts
      )
      decorator = EventDecorator.for(event)
      expected_time = Time.at(ts / 1_000_000_000.0).strftime("%H:%M:%S")

      expect(decorator.render_verbose).to eq(["[#{expected_time}] [system] retrying after error"])
    end

    it "shows placeholder when timestamp is nil" do
      decorator = EventDecorator.for(type: "system_message", content: "boot")

      expect(decorator.render_verbose).to eq(["[--:--:--] [system] boot"])
    end
  end
end
