# frozen_string_literal: true

require "rails_helper"

RSpec.describe ToolCallDecorator do
  let(:session) { Session.create! }

  describe "#render_basic" do
    it "returns nil (hidden in basic mode)" do
      event = session.events.create!(
        event_type: "tool_call",
        payload: {"content" => "calling bash", "tool_name" => "bash", "tool_input" => {"cmd" => "ls"}},
        timestamp: 1
      )
      decorator = EventDecorator.for(event)

      expect(decorator.render_basic).to be_nil
    end

    it "returns nil for hash payloads" do
      decorator = EventDecorator.for(type: "tool_call", content: "calling bash", tool_name: "bash")

      expect(decorator.render_basic).to be_nil
    end
  end
end
