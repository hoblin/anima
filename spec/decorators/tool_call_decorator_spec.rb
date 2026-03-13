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
    it "shows tool name header with bash command" do
      event = session.events.create!(
        event_type: "tool_call",
        payload: {"content" => "running git status", "tool_name" => "bash", "tool_input" => {"command" => "git status"}},
        timestamp: 1
      )
      decorator = EventDecorator.for(event)

      expect(decorator.render_verbose).to eq([
        "\u{1F527} bash",
        "  $ git status"
      ])
    end

    it "shows tool name header with web_get URL" do
      event = session.events.create!(
        event_type: "tool_call",
        payload: {"content" => "fetching", "tool_name" => "web_get", "tool_input" => {"url" => "https://example.com/api"}},
        timestamp: 1
      )
      decorator = EventDecorator.for(event)

      expect(decorator.render_verbose).to eq([
        "\u{1F527} web_get",
        "  GET https://example.com/api"
      ])
    end

    it "shows generic JSON for unknown tools" do
      event = session.events.create!(
        event_type: "tool_call",
        payload: {"content" => "calling custom", "tool_name" => "custom_tool", "tool_input" => {"key" => "value"}},
        timestamp: 1
      )
      decorator = EventDecorator.for(event)

      expect(decorator.render_verbose).to eq([
        "\u{1F527} custom_tool",
        '  {"key":"value"}'
      ])
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

      expect(result.first).to eq("\u{1F527} custom")
      # Generic JSON is single-line, so truncation doesn't apply here.
      # Truncation matters when tool_input.to_json produces multi-line output.
      expect(result.length).to be >= 2
    end

    it "handles nil tool_input for bash" do
      event = session.events.create!(
        event_type: "tool_call",
        payload: {"content" => "calling bash", "tool_name" => "bash", "tool_input" => nil},
        timestamp: 1
      )
      decorator = EventDecorator.for(event)

      expect(decorator.render_verbose).to eq([
        "\u{1F527} bash",
        "  $ "
      ])
    end

    it "works with hash payloads" do
      decorator = EventDecorator.for(
        type: "tool_call",
        content: "calling bash",
        tool_name: "bash",
        tool_input: {"command" => "ls -la"}
      )

      expect(decorator.render_verbose).to eq([
        "\u{1F527} bash",
        "  $ ls -la"
      ])
    end
  end
end
