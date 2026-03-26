# frozen_string_literal: true

require "rails_helper"

RSpec.describe ToolResponseDecorator, type: :decorator do
  let(:session) { Session.create! }

  describe "#render_basic" do
    it "returns nil (hidden in basic mode)" do
      event = session.messages.create!(
        message_type: "tool_response",
        payload: {"content" => "file.txt", "tool_name" => "bash", "success" => true},
        tool_use_id: "toolu_basic1",
        timestamp: 1
      )
      decorator = MessageDecorator.for(event)

      expect(decorator.render_basic).to be_nil
    end

    it "returns nil for hash payloads" do
      decorator = MessageDecorator.for(type: "tool_response", content: "output", tool_name: "bash")

      expect(decorator.render_basic).to be_nil
    end

    it "returns nil for think tool responses" do
      event = session.messages.create!(
        message_type: "tool_response",
        payload: {"content" => "OK", "tool_name" => "think", "success" => true},
        tool_use_id: "toolu_think_r1",
        timestamp: 1
      )
      decorator = MessageDecorator.for(event)

      expect(decorator.render_basic).to be_nil
    end
  end

  describe "#render_verbose" do
    it "returns structured hash with success for successful output" do
      event = session.messages.create!(
        message_type: "tool_response",
        payload: {"content" => "file.txt", "tool_name" => "bash", "success" => true},
        tool_use_id: "toolu_verbose1",
        timestamp: 1
      )
      decorator = MessageDecorator.for(event)

      expect(decorator.render_verbose).to eq({
        role: :tool_response, tool: "bash", content: "file.txt", success: true, timestamp: 1
      })
    end

    it "returns structured hash with success false for failed tool" do
      event = session.messages.create!(
        message_type: "tool_response",
        payload: {"content" => "command not found", "tool_name" => "bash", "success" => false},
        tool_use_id: "toolu_verbose2",
        timestamp: 1
      )
      decorator = MessageDecorator.for(event)

      expect(decorator.render_verbose).to eq({
        role: :tool_response, tool: "bash", content: "command not found", success: false, timestamp: 1
      })
    end

    it "truncates output exceeding 3 lines" do
      long_output = "line1\nline2\nline3\nline4\nline5"
      event = session.messages.create!(
        message_type: "tool_response",
        payload: {"content" => long_output, "tool_name" => "bash", "success" => true},
        tool_use_id: "toolu_verbose3",
        timestamp: 1
      )
      decorator = MessageDecorator.for(event)
      result = decorator.render_verbose

      expect(result[:content]).to eq("line1\nline2\nline3\n...")
      expect(result[:success]).to be true
    end

    it "preserves multiline output within the limit" do
      output = "line1\nline2\nline3"
      event = session.messages.create!(
        message_type: "tool_response",
        payload: {"content" => output, "tool_name" => "bash", "success" => true},
        tool_use_id: "toolu_verbose4",
        timestamp: 1
      )
      decorator = MessageDecorator.for(event)

      expect(decorator.render_verbose[:content]).to eq("line1\nline2\nline3")
    end

    it "handles nil content" do
      event = session.messages.create!(
        message_type: "tool_response",
        payload: {"content" => nil, "tool_name" => "bash", "success" => true},
        tool_use_id: "toolu_verbose5",
        timestamp: 1
      )
      decorator = MessageDecorator.for(event)

      expect(decorator.render_verbose[:content]).to eq("")
    end

    it "handles empty content" do
      event = session.messages.create!(
        message_type: "tool_response",
        payload: {"content" => "", "tool_name" => "bash", "success" => true},
        tool_use_id: "toolu_verbose6",
        timestamp: 1
      )
      decorator = MessageDecorator.for(event)

      expect(decorator.render_verbose[:content]).to eq("")
    end

    it "defaults success to true when field is missing" do
      event = session.messages.create!(
        message_type: "tool_response",
        payload: {"content" => "output", "tool_name" => "bash"},
        tool_use_id: "toolu_verbose7",
        timestamp: 1
      )
      decorator = MessageDecorator.for(event)

      expect(decorator.render_verbose[:success]).to be true
    end

    it "works with hash payloads" do
      decorator = MessageDecorator.for(
        type: "tool_response",
        content: "success output",
        tool_name: "bash",
        success: true
      )

      expect(decorator.render_verbose).to eq({
        role: :tool_response, tool: "bash", content: "success output", success: true, timestamp: nil
      })
    end

    context "think tool" do
      it "returns nil for think responses (noise suppression)" do
        event = session.messages.create!(
          message_type: "tool_response",
          payload: {"content" => "OK", "tool_name" => "think", "success" => true},
          tool_use_id: "toolu_think_v1",
          timestamp: 1
        )
        decorator = MessageDecorator.for(event)

        expect(decorator.render_verbose).to be_nil
      end

      it "returns nil for think responses via hash payload" do
        decorator = MessageDecorator.for(
          type: "tool_response",
          content: "OK",
          tool_name: "think",
          success: true
        )

        expect(decorator.render_verbose).to be_nil
      end
    end
  end

  describe "#render_debug" do
    it "returns full untruncated content" do
      long_output = "line1\nline2\nline3\nline4\nline5"
      event = session.messages.create!(
        message_type: "tool_response",
        payload: {
          "content" => long_output, "tool_name" => "bash",
          "success" => true, "tool_use_id" => "toolu_01abc123"
        },
        timestamp: 1,
        tool_use_id: "toolu_01abc123"
      )
      decorator = MessageDecorator.for(event)
      result = decorator.render_debug

      expect(result[:content]).to eq(long_output)
      expect(result[:content]).not_to include("...")
    end

    it "includes tool_use_id and success indicator" do
      event = session.messages.create!(
        message_type: "tool_response",
        payload: {
          "content" => "output", "tool_name" => "bash",
          "success" => true, "tool_use_id" => "toolu_xyz"
        },
        timestamp: 1,
        tool_use_id: "toolu_xyz"
      )
      decorator = MessageDecorator.for(event)
      result = decorator.render_debug

      expect(result[:tool_use_id]).to eq("toolu_xyz")
      expect(result[:success]).to be true
    end

    it "shows failure status" do
      event = session.messages.create!(
        message_type: "tool_response",
        payload: {
          "content" => "command not found", "tool_name" => "bash",
          "success" => false, "tool_use_id" => "toolu_fail"
        },
        timestamp: 1,
        tool_use_id: "toolu_fail"
      )
      decorator = MessageDecorator.for(event)
      result = decorator.render_debug

      expect(result[:success]).to be false
    end

    it "includes estimated token count" do
      event = session.messages.create!(
        message_type: "tool_response",
        payload: {"content" => "some output", "tool_name" => "bash", "success" => true},
        tool_use_id: "toolu_tokens1",
        timestamp: 1
      )
      decorator = MessageDecorator.for(event)
      result = decorator.render_debug

      expect(result[:tokens]).to be_positive
      expect(result[:estimated]).to be true
    end

    it "works with hash payloads" do
      decorator = MessageDecorator.for(
        type: "tool_response",
        content: "output text",
        tool_name: "bash",
        success: true,
        tool_use_id: "toolu_hash"
      )
      result = decorator.render_debug

      expect(result[:role]).to eq(:tool_response)
      expect(result[:content]).to eq("output text")
      expect(result[:tool_use_id]).to eq("toolu_hash")
      expect(result[:tokens]).to be_positive
    end

    context "think tool" do
      it "shows think responses in debug mode (for completeness)" do
        event = session.messages.create!(
          message_type: "tool_response",
          payload: {
            "content" => "OK", "tool_name" => "think",
            "success" => true, "tool_use_id" => "toolu_think_r1"
          },
          timestamp: 1,
          tool_use_id: "toolu_think_r1"
        )
        decorator = MessageDecorator.for(event)
        result = decorator.render_debug

        expect(result[:role]).to eq(:tool_response)
        expect(result[:content]).to eq("OK")
        expect(result[:tool_use_id]).to eq("toolu_think_r1")
      end
    end
  end

  describe "#render_brain" do
    it "returns ✅ for successful tool responses" do
      event = session.messages.create!(
        message_type: "tool_response",
        payload: {"content" => "file1.rb\nfile2.rb", "tool_name" => "bash", "success" => true},
        tool_use_id: "toolu_brain1",
        timestamp: 1
      )
      decorator = MessageDecorator.for(event)

      expect(decorator.render_brain).to eq("\u2705")
    end

    it "returns ❌ for failed tool responses" do
      event = session.messages.create!(
        message_type: "tool_response",
        payload: {"content" => "command not found", "tool_name" => "bash", "success" => false},
        tool_use_id: "toolu_brain2",
        timestamp: 1
      )
      decorator = MessageDecorator.for(event)

      expect(decorator.render_brain).to eq("\u274C")
    end

    it "returns nil for think tool responses" do
      event = session.messages.create!(
        message_type: "tool_response",
        payload: {"content" => "OK", "tool_name" => "think", "success" => true},
        tool_use_id: "toolu_brain3",
        timestamp: 1
      )
      decorator = MessageDecorator.for(event)

      expect(decorator.render_brain).to be_nil
    end

    it "defaults to ✅ when success field is missing" do
      event = session.messages.create!(
        message_type: "tool_response",
        payload: {"content" => "output", "tool_name" => "bash"},
        tool_use_id: "toolu_brain4",
        timestamp: 1
      )
      decorator = MessageDecorator.for(event)

      expect(decorator.render_brain).to eq("\u2705")
    end
  end
end
