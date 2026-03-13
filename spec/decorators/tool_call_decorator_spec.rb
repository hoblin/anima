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

    it "renders compact JSON for generic tool input" do
      input = {"a" => "1\n2\n3\n4\n5"}
      event = session.events.create!(
        event_type: "tool_call",
        payload: {"content" => "calling", "tool_name" => "custom", "tool_input" => input},
        timestamp: 1
      )
      decorator = EventDecorator.for(event)

      expect(decorator.render_verbose).to eq({
        role: :tool_call, tool: "custom", input: input.to_json, timestamp: 1
      })
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

      expect(decorator.render_verbose).to eq({
        role: :tool_call, tool: "bash", input: "$ ls -la", timestamp: nil
      })
    end
  end

  describe "#render_debug" do
    it "returns full untruncated input as pretty-printed JSON" do
      input = {"command" => "git status"}
      event = session.events.create!(
        event_type: "tool_call",
        payload: {
          "content" => "running git status", "tool_name" => "bash",
          "tool_input" => input, "tool_use_id" => "toolu_01abc123"
        },
        timestamp: 1,
        tool_use_id: "toolu_01abc123"
      )
      decorator = EventDecorator.for(event)

      expect(decorator.render_debug).to eq({
        role: :tool_call,
        tool: "bash",
        input: JSON.pretty_generate(input),
        tool_use_id: "toolu_01abc123",
        timestamp: 1
      })
    end

    it "includes tool_use_id from payload" do
      event = session.events.create!(
        event_type: "tool_call",
        payload: {
          "content" => "calling", "tool_name" => "web_get",
          "tool_input" => {"url" => "https://example.com"}, "tool_use_id" => "toolu_xyz"
        },
        timestamp: 1,
        tool_use_id: "toolu_xyz"
      )
      decorator = EventDecorator.for(event)
      result = decorator.render_debug

      expect(result[:tool_use_id]).to eq("toolu_xyz")
    end

    it "shows full input without truncation for complex payloads" do
      large_input = {"a" => "1", "b" => "2", "c" => "3", "d" => "4", "e" => "5"}
      event = session.events.create!(
        event_type: "tool_call",
        payload: {
          "content" => "calling", "tool_name" => "custom",
          "tool_input" => large_input, "tool_use_id" => "toolu_big"
        },
        timestamp: 1,
        tool_use_id: "toolu_big"
      )
      decorator = EventDecorator.for(event)
      result = decorator.render_debug

      expect(result[:input]).to eq(JSON.pretty_generate(large_input))
      expect(result[:input]).not_to include("...")
    end

    it "handles nil tool_input" do
      event = session.events.create!(
        event_type: "tool_call",
        payload: {"content" => "calling", "tool_name" => "bash", "tool_input" => nil},
        timestamp: 1
      )
      decorator = EventDecorator.for(event)
      result = decorator.render_debug

      expect(result[:input]).to eq(JSON.pretty_generate({}))
    end

    it "works with hash payloads" do
      decorator = EventDecorator.for(
        type: "tool_call",
        content: "calling bash",
        tool_name: "bash",
        tool_input: {"command" => "ls"},
        tool_use_id: "toolu_hash"
      )
      result = decorator.render_debug

      expect(result[:role]).to eq(:tool_call)
      expect(result[:tool]).to eq("bash")
      expect(result[:tool_use_id]).to eq("toolu_hash")
      expect(result[:input]).to eq(JSON.pretty_generate({"command" => "ls"}))
    end
  end
end
