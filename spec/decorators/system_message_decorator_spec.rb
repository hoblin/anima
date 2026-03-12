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
end
