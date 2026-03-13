# frozen_string_literal: true

require "rails_helper"

RSpec.describe ToolResponseDecorator, type: :decorator do
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

  describe "#render_verbose" do
    it "shows return arrow with successful output" do
      event = session.events.create!(
        event_type: "tool_response",
        payload: {"content" => "file.txt", "tool_name" => "bash", "success" => true},
        timestamp: 1
      )
      decorator = EventDecorator.for(event)

      expect(decorator.render_verbose).to eq(["  \u21A9 file.txt"])
    end

    it "shows error indicator for failed tool" do
      event = session.events.create!(
        event_type: "tool_response",
        payload: {"content" => "command not found", "tool_name" => "bash", "success" => false},
        timestamp: 1
      )
      decorator = EventDecorator.for(event)

      expect(decorator.render_verbose).to eq(["  \u274C command not found"])
    end

    it "truncates output exceeding 3 lines" do
      long_output = "line1\nline2\nline3\nline4\nline5"
      event = session.events.create!(
        event_type: "tool_response",
        payload: {"content" => long_output, "tool_name" => "bash", "success" => true},
        timestamp: 1
      )
      decorator = EventDecorator.for(event)
      result = decorator.render_verbose

      expect(result).to eq([
        "  \u21A9 line1",
        "    line2",
        "    line3",
        "    ..."
      ])
    end

    it "preserves multiline output within the limit" do
      output = "line1\nline2\nline3"
      event = session.events.create!(
        event_type: "tool_response",
        payload: {"content" => output, "tool_name" => "bash", "success" => true},
        timestamp: 1
      )
      decorator = EventDecorator.for(event)

      expect(decorator.render_verbose).to eq([
        "  \u21A9 line1",
        "    line2",
        "    line3"
      ])
    end

    it "handles nil content" do
      event = session.events.create!(
        event_type: "tool_response",
        payload: {"content" => nil, "tool_name" => "bash", "success" => true},
        timestamp: 1
      )
      decorator = EventDecorator.for(event)

      expect(decorator.render_verbose).to eq(["  \u21A9 "])
    end

    it "handles empty content" do
      event = session.events.create!(
        event_type: "tool_response",
        payload: {"content" => "", "tool_name" => "bash", "success" => true},
        timestamp: 1
      )
      decorator = EventDecorator.for(event)

      expect(decorator.render_verbose).to eq(["  \u21A9 "])
    end

    it "shows return arrow when success field is missing" do
      event = session.events.create!(
        event_type: "tool_response",
        payload: {"content" => "output", "tool_name" => "bash"},
        timestamp: 1
      )
      decorator = EventDecorator.for(event)

      expect(decorator.render_verbose).to eq(["  \u21A9 output"])
    end

    it "works with hash payloads" do
      decorator = EventDecorator.for(
        type: "tool_response",
        content: "success output",
        tool_name: "bash",
        success: true
      )

      expect(decorator.render_verbose).to eq(["  \u21A9 success output"])
    end
  end
end
