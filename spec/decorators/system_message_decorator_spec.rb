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
    it "returns structured hash with system role and timestamp" do
      ts = 1_709_312_325_000_000_000
      event = session.events.create!(
        event_type: "system_message",
        payload: {"content" => "retrying after error"},
        timestamp: ts
      )
      decorator = EventDecorator.for(event)

      expect(decorator.render_verbose).to eq({
        role: :system, content: "retrying after error", timestamp: ts
      })
    end

    it "includes nil timestamp when missing" do
      decorator = EventDecorator.for(type: "system_message", content: "boot")

      expect(decorator.render_verbose).to eq({role: :system, content: "boot", timestamp: nil})
    end
  end

  describe "#render_debug" do
    it "returns same structure as verbose" do
      ts = 1_709_312_325_000_000_000
      event = session.events.create!(
        event_type: "system_message",
        payload: {"content" => "retrying after error"},
        timestamp: ts
      )
      decorator = EventDecorator.for(event)

      expect(decorator.render_debug).to eq({
        role: :system, content: "retrying after error", timestamp: ts
      })
    end

    it "works with hash payloads" do
      decorator = EventDecorator.for(type: "system_message", content: "boot")

      expect(decorator.render_debug).to eq({role: :system, content: "boot", timestamp: nil})
    end
  end
end
