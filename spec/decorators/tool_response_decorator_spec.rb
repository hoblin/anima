# frozen_string_literal: true

require "rails_helper"

RSpec.describe ToolResponseDecorator do
  let(:session) { Session.create! }

  describe "#render_basic" do
    it "returns nil (hidden in basic mode)" do
      event = session.events.create!(
        event_type: "tool_response",
        payload: {"content" => "file.txt", "tool_name" => "bash", "success" => true},
        timestamp: 1
      )
      decorator = EventDecorator.for(event)

      expect(decorator.render_basic).to be_nil
    end

    it "returns nil for hash payloads" do
      decorator = EventDecorator.for(type: "tool_response", content: "output", tool_name: "bash")

      expect(decorator.render_basic).to be_nil
    end
  end
end
