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
    it "returns structured hash with success for successful output" do
      event = session.events.create!(
        event_type: "tool_response",
        payload: {"content" => "file.txt", "tool_name" => "bash", "success" => true},
        timestamp: 1
      )
      decorator = EventDecorator.for(event)

      expect(decorator.render_verbose).to eq({
        role: :tool_response, content: "file.txt", success: true, timestamp: 1
      })
    end

    it "returns structured hash with success false for failed tool" do
      event = session.events.create!(
        event_type: "tool_response",
        payload: {"content" => "command not found", "tool_name" => "bash", "success" => false},
        timestamp: 1
      )
      decorator = EventDecorator.for(event)

      expect(decorator.render_verbose).to eq({
        role: :tool_response, content: "command not found", success: false, timestamp: 1
      })
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

      expect(result[:content]).to eq("line1\nline2\nline3\n...")
      expect(result[:success]).to be true
    end

    it "preserves multiline output within the limit" do
      output = "line1\nline2\nline3"
      event = session.events.create!(
        event_type: "tool_response",
        payload: {"content" => output, "tool_name" => "bash", "success" => true},
        timestamp: 1
      )
      decorator = EventDecorator.for(event)

      expect(decorator.render_verbose[:content]).to eq("line1\nline2\nline3")
    end

    it "handles nil content" do
      event = session.events.create!(
        event_type: "tool_response",
        payload: {"content" => nil, "tool_name" => "bash", "success" => true},
        timestamp: 1
      )
      decorator = EventDecorator.for(event)

      expect(decorator.render_verbose[:content]).to eq("")
    end

    it "handles empty content" do
      event = session.events.create!(
        event_type: "tool_response",
        payload: {"content" => "", "tool_name" => "bash", "success" => true},
        timestamp: 1
      )
      decorator = EventDecorator.for(event)

      expect(decorator.render_verbose[:content]).to eq("")
    end

    it "defaults success to true when field is missing" do
      event = session.events.create!(
        event_type: "tool_response",
        payload: {"content" => "output", "tool_name" => "bash"},
        timestamp: 1
      )
      decorator = EventDecorator.for(event)

      expect(decorator.render_verbose[:success]).to be true
    end

    it "works with hash payloads" do
      decorator = EventDecorator.for(
        type: "tool_response",
        content: "success output",
        tool_name: "bash",
        success: true
      )

      expect(decorator.render_verbose).to include(
        role: :tool_response, content: "success output", success: true
      )
    end
  end
end
