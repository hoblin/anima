# frozen_string_literal: true

require "rails_helper"

RSpec.describe EventDecorator, type: :decorator do
  let(:session) { Session.create! }

  describe ".for" do
    context "with Event AR models" do
      it "returns UserMessageDecorator for user_message events" do
        event = session.events.create!(event_type: "user_message", payload: {"content" => "hi"}, timestamp: 1)

        expect(described_class.for(event)).to be_a(UserMessageDecorator)
      end

      it "returns AgentMessageDecorator for agent_message events" do
        event = session.events.create!(event_type: "agent_message", payload: {"content" => "hello"}, timestamp: 1)

        expect(described_class.for(event)).to be_a(AgentMessageDecorator)
      end

      it "returns ToolCallDecorator for tool_call events" do
        event = session.events.create!(event_type: "tool_call", payload: {"content" => "calling bash"}, timestamp: 1)

        expect(described_class.for(event)).to be_a(ToolCallDecorator)
      end

      it "returns ToolResponseDecorator for tool_response events" do
        event = session.events.create!(event_type: "tool_response", payload: {"content" => "output"}, timestamp: 1)

        expect(described_class.for(event)).to be_a(ToolResponseDecorator)
      end

      it "returns SystemMessageDecorator for system_message events" do
        event = session.events.create!(event_type: "system_message", payload: {"content" => "boot"}, timestamp: 1)

        expect(described_class.for(event)).to be_a(SystemMessageDecorator)
      end
    end

    context "with hash payloads (from EventBus)" do
      it "returns UserMessageDecorator for user_message hash" do
        expect(described_class.for(type: "user_message", content: "hi")).to be_a(UserMessageDecorator)
      end

      it "returns AgentMessageDecorator for agent_message hash" do
        expect(described_class.for(type: "agent_message", content: "hello")).to be_a(AgentMessageDecorator)
      end

      it "returns ToolCallDecorator for tool_call hash" do
        expect(described_class.for(type: "tool_call", content: "calling bash")).to be_a(ToolCallDecorator)
      end

      it "returns ToolResponseDecorator for tool_response hash" do
        expect(described_class.for(type: "tool_response", content: "output")).to be_a(ToolResponseDecorator)
      end

      it "returns SystemMessageDecorator for system_message hash" do
        expect(described_class.for(type: "system_message", content: "boot")).to be_a(SystemMessageDecorator)
      end

      it "returns nil for unknown event types" do
        expect(described_class.for(type: "unknown", content: "wat")).to be_nil
      end

      it "handles string-keyed hashes" do
        expect(described_class.for("type" => "user_message", "content" => "hi")).to be_a(UserMessageDecorator)
      end
    end
  end

  describe "#render" do
    it "dispatches to render_basic for basic mode" do
      event = session.events.create!(event_type: "user_message", payload: {"content" => "hi"}, timestamp: 1)
      decorator = described_class.for(event)

      expect(decorator.render("basic")).to eq({role: :user, content: "hi"})
    end

    it "dispatches to render_verbose for verbose mode" do
      ts = 1_709_312_325_000_000_000
      event = session.events.create!(event_type: "user_message", payload: {"content" => "hi"}, timestamp: ts)
      decorator = described_class.for(event)

      expect(decorator.render("verbose")).to eq({role: :user, content: "hi", timestamp: ts})
    end

    it "dispatches to render_debug for debug mode" do
      event = session.events.create!(event_type: "user_message", payload: {"content" => "hi"}, timestamp: 1)
      decorator = described_class.for(event)

      # Debug still delegates to basic until #77 implements it
      expect(decorator.render("debug")).to eq({role: :user, content: "hi"})
    end

    it "raises ArgumentError for invalid mode" do
      event = session.events.create!(event_type: "user_message", payload: {"content" => "hi"}, timestamp: 1)
      decorator = described_class.for(event)

      expect { decorator.render("hacker_mode") }.to raise_error(ArgumentError, /Invalid view mode/)
    end

    it "raises ArgumentError for nil mode" do
      event = session.events.create!(event_type: "user_message", payload: {"content" => "hi"}, timestamp: 1)
      decorator = described_class.for(event)

      expect { decorator.render(nil) }.to raise_error(ArgumentError, /Invalid view mode/)
    end
  end

  describe "#render_verbose" do
    it "delegates to render_basic by default in base class" do
      # Verify the base class delegation pattern — subclasses may override
      stub_decorator = Class.new(described_class) do
        def render_basic
          {role: :stub, content: "stub output"}
        end
      end
      source = described_class.send(:wrap_source, {type: "user_message", content: "hi"})
      decorator = stub_decorator.new(source)

      expect(decorator.render_verbose).to eq({role: :stub, content: "stub output"})
    end
  end

  describe "#render_debug" do
    it "delegates to render_basic by default" do
      event = session.events.create!(event_type: "user_message", payload: {"content" => "hi"}, timestamp: 1)
      decorator = described_class.for(event)

      expect(decorator.render_debug).to eq(decorator.render_basic)
    end
  end

  describe "#truncate_lines (private)" do
    let(:decorator) do
      event = session.events.create!(event_type: "user_message", payload: {"content" => "hi"}, timestamp: 1)
      described_class.for(event)
    end

    it "returns text unchanged when under the limit" do
      expect(decorator.send(:truncate_lines, "line1\nline2", max_lines: 3)).to eq("line1\nline2")
    end

    it "returns text unchanged when exactly at the limit" do
      expect(decorator.send(:truncate_lines, "line1\nline2\nline3", max_lines: 3)).to eq("line1\nline2\nline3")
    end

    it "truncates and appends ellipsis when over the limit" do
      expect(decorator.send(:truncate_lines, "line1\nline2\nline3\nline4", max_lines: 2)).to eq("line1\nline2\n...")
    end

    it "handles nil text" do
      expect(decorator.send(:truncate_lines, nil, max_lines: 3)).to eq("")
    end

    it "handles empty text" do
      expect(decorator.send(:truncate_lines, "", max_lines: 3)).to eq("")
    end
  end
end
