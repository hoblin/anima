# frozen_string_literal: true

require "rails_helper"

RSpec.describe ToolCallDecorator, type: :decorator do
  let(:session) { Session.create! }

  describe "#render_basic" do
    it "returns nil (hidden in basic mode)" do
      event = session.events.create!(
        event_type: "tool_call",
        payload: {"content" => "calling bash", "tool_name" => "bash", "tool_input" => {"command" => "ls"}},
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

  describe "#render_verbose" do
    it "returns structured hash with tool name and bash command" do
      event = session.events.create!(
        event_type: "tool_call",
        payload: {"content" => "running git status", "tool_name" => "bash", "tool_input" => {"command" => "git status"}},
        timestamp: 1
      )
      decorator = EventDecorator.for(event)

      expect(decorator.render_verbose).to eq({
        role: :tool_call, tool: "bash", input: "$ git status", timestamp: 1
      })
    end

    it "returns structured hash with web_get URL" do
      event = session.events.create!(
        event_type: "tool_call",
        payload: {"content" => "fetching", "tool_name" => "web_get", "tool_input" => {"url" => "https://example.com/api"}},
        timestamp: 1
      )
      decorator = EventDecorator.for(event)

      expect(decorator.render_verbose).to eq({
        role: :tool_call, tool: "web_get", input: "GET https://example.com/api", timestamp: 1
      })
    end

    it "returns generic JSON for unknown tools" do
      event = session.events.create!(
        event_type: "tool_call",
        payload: {"content" => "calling custom", "tool_name" => "custom_tool", "tool_input" => {"key" => "value"}},
        timestamp: 1
      )
      decorator = EventDecorator.for(event)

      expect(decorator.render_verbose).to eq({
        role: :tool_call, tool: "custom_tool", input: '{"key":"value"}', timestamp: 1
      })
    end

    it "truncates long generic input to 2 lines" do
      long_input = {"a" => "1\n2\n3\n4\n5"}
      event = session.events.create!(
        event_type: "tool_call",
        payload: {"content" => "calling", "tool_name" => "custom", "tool_input" => long_input},
        timestamp: 1
      )
      decorator = EventDecorator.for(event)
      result = decorator.render_verbose

      expect(result[:role]).to eq(:tool_call)
      expect(result[:tool]).to eq("custom")
      expect(result[:input]).to be_a(String)
    end

    it "handles nil tool_input for bash" do
      event = session.events.create!(
        event_type: "tool_call",
        payload: {"content" => "calling bash", "tool_name" => "bash", "tool_input" => nil},
        timestamp: 1
      )
      decorator = EventDecorator.for(event)

      expect(decorator.render_verbose).to eq({
        role: :tool_call, tool: "bash", input: "$ ", timestamp: 1
      })
    end

    it "works with hash payloads" do
      decorator = EventDecorator.for(
        type: "tool_call",
        content: "calling bash",
        tool_name: "bash",
        tool_input: {"command" => "ls -la"}
      )

      expect(decorator.render_verbose).to include(
        role: :tool_call, tool: "bash", input: "$ ls -la"
      )
    end
  end
end
