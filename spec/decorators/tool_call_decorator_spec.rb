# frozen_string_literal: true

require "rails_helper"

RSpec.describe ToolCallDecorator, type: :decorator do
  let(:session) { Session.create! }

  describe "#render_basic" do
    it "returns nil (hidden in basic mode)" do
      event = session.messages.create!(
        message_type: "tool_call",
        payload: {"content" => "calling bash", "tool_name" => "bash", "tool_input" => {"command" => "ls"}},
        tool_use_id: "toolu_basic1",
        timestamp: 1
      )
      decorator = MessageDecorator.for(event)

      expect(decorator.render_basic).to be_nil
    end

    it "returns nil for hash payloads" do
      decorator = MessageDecorator.for(type: "tool_call", content: "calling bash", tool_name: "bash")

      expect(decorator.render_basic).to be_nil
    end

    context "think tool" do
      it "returns nil for inner thoughts (default)" do
        event = session.messages.create!(
          message_type: "tool_call",
          payload: {"content" => "thinking", "tool_name" => "think", "tool_input" => {"thoughts" => "Planning next step"}},
          tool_use_id: "toolu_think1",
          timestamp: 1
        )
        decorator = MessageDecorator.for(event)

        expect(decorator.render_basic).to be_nil
      end

      it "returns nil for explicitly inner thoughts" do
        event = session.messages.create!(
          message_type: "tool_call",
          payload: {"content" => "thinking", "tool_name" => "think",
                    "tool_input" => {"thoughts" => "Planning next step", "visibility" => "inner"}},
          tool_use_id: "toolu_think2",
          timestamp: 1
        )
        decorator = MessageDecorator.for(event)

        expect(decorator.render_basic).to be_nil
      end

      it "returns structured hash for aloud thoughts" do
        event = session.messages.create!(
          message_type: "tool_call",
          payload: {"content" => "thinking aloud", "tool_name" => "think",
                    "tool_input" => {"thoughts" => "Checking the config first.", "visibility" => "aloud"}},
          tool_use_id: "toolu_think3",
          timestamp: 1
        )
        decorator = MessageDecorator.for(event)

        expect(decorator.render_basic).to eq({
          role: :think, content: "Checking the config first.", visibility: "aloud"
        })
      end

      it "works with hash payloads for aloud thoughts" do
        decorator = MessageDecorator.for(
          type: "tool_call",
          content: "thinking",
          tool_name: "think",
          tool_input: {"thoughts" => "Narrating", "visibility" => "aloud"}
        )

        expect(decorator.render_basic).to eq({
          role: :think, content: "Narrating", visibility: "aloud"
        })
      end
    end
  end

  describe "#render_verbose" do
    it "returns structured hash with tool name and bash command" do
      event = session.messages.create!(
        message_type: "tool_call",
        payload: {"content" => "running git status", "tool_name" => "bash", "tool_input" => {"command" => "git status"}},
        tool_use_id: "toolu_verbose1",
        timestamp: 1
      )
      decorator = MessageDecorator.for(event)

      expect(decorator.render_verbose).to eq({
        role: :tool_call, tool: "bash", input: "$ git status", timestamp: 1
      })
    end

    it "returns structured hash with web_get URL" do
      event = session.messages.create!(
        message_type: "tool_call",
        payload: {"content" => "fetching", "tool_name" => "web_get", "tool_input" => {"url" => "https://example.com/api"}},
        tool_use_id: "toolu_verbose2",
        timestamp: 1
      )
      decorator = MessageDecorator.for(event)

      expect(decorator.render_verbose).to eq({
        role: :tool_call, tool: "web_get", input: "GET https://example.com/api", timestamp: 1
      })
    end

    it "returns file path for read_file tool" do
      event = session.messages.create!(
        message_type: "tool_call",
        payload: {"content" => "reading", "tool_name" => "read_file",
                  "tool_input" => {"file_path" => "/app/models/user.rb"}},
        tool_use_id: "toolu_verbose3",
        timestamp: 1
      )
      decorator = MessageDecorator.for(event)

      expect(decorator.render_verbose).to eq({
        role: :tool_call, tool: "read_file", input: "/app/models/user.rb", timestamp: 1
      })
    end

    it "returns file path for edit_file tool" do
      event = session.messages.create!(
        message_type: "tool_call",
        payload: {"content" => "editing", "tool_name" => "edit_file",
                  "tool_input" => {"file_path" => "/app/models/user.rb", "changes" => "..."}},
        tool_use_id: "toolu_verbose4",
        timestamp: 1
      )
      decorator = MessageDecorator.for(event)

      expect(decorator.render_verbose).to eq({
        role: :tool_call, tool: "edit_file", input: "/app/models/user.rb", timestamp: 1
      })
    end

    it "returns file path for write_file tool" do
      event = session.messages.create!(
        message_type: "tool_call",
        payload: {"content" => "writing", "tool_name" => "write_file",
                  "tool_input" => {"file_path" => "/tmp/output.txt", "content" => "data"}},
        tool_use_id: "toolu_verbose5",
        timestamp: 1
      )
      decorator = MessageDecorator.for(event)

      expect(decorator.render_verbose).to eq({
        role: :tool_call, tool: "write_file", input: "/tmp/output.txt", timestamp: 1
      })
    end

    it "returns TOON-encoded input for unknown tools" do
      event = session.messages.create!(
        message_type: "tool_call",
        payload: {"content" => "calling custom", "tool_name" => "custom_tool", "tool_input" => {"key" => "value"}},
        tool_use_id: "toolu_verbose6",
        timestamp: 1
      )
      decorator = MessageDecorator.for(event)

      expect(decorator.render_verbose).to eq({
        role: :tool_call, tool: "custom_tool", input: "key: value", timestamp: 1
      })
    end

    it "truncates TOON-encoded input for generic tool input" do
      input = {"a" => "1\n2\n3\n4\n5"}
      event = session.messages.create!(
        message_type: "tool_call",
        payload: {"content" => "calling", "tool_name" => "custom", "tool_input" => input},
        tool_use_id: "toolu_verbose7",
        timestamp: 1
      )
      decorator = MessageDecorator.for(event)

      expect(decorator.render_verbose).to eq({
        role: :tool_call, tool: "custom", input: Toon.encode(input), timestamp: 1
      })
    end

    it "handles nil tool_input for bash" do
      event = session.messages.create!(
        message_type: "tool_call",
        payload: {"content" => "calling bash", "tool_name" => "bash", "tool_input" => nil},
        tool_use_id: "toolu_verbose8",
        timestamp: 1
      )
      decorator = MessageDecorator.for(event)

      expect(decorator.render_verbose).to eq({
        role: :tool_call, tool: "bash", input: "$ ", timestamp: 1
      })
    end

    it "works with hash payloads" do
      decorator = MessageDecorator.for(
        type: "tool_call",
        content: "calling bash",
        tool_name: "bash",
        tool_input: {"command" => "ls -la"}
      )

      expect(decorator.render_verbose).to eq({
        role: :tool_call, tool: "bash", input: "$ ls -la", timestamp: nil
      })
    end

    context "think tool" do
      it "returns think role with inner visibility" do
        event = session.messages.create!(
          message_type: "tool_call",
          payload: {"content" => "thinking", "tool_name" => "think",
                    "tool_input" => {"thoughts" => "I should check the logs", "visibility" => "inner"}},
          tool_use_id: "toolu_think_v1",
          timestamp: 1
        )
        decorator = MessageDecorator.for(event)

        expect(decorator.render_verbose).to eq({
          role: :think, content: "I should check the logs", visibility: "inner", timestamp: 1
        })
      end

      it "returns think role with aloud visibility" do
        event = session.messages.create!(
          message_type: "tool_call",
          payload: {"content" => "thinking", "tool_name" => "think",
                    "tool_input" => {"thoughts" => "Checking the logs now", "visibility" => "aloud"}},
          tool_use_id: "toolu_think_v2",
          timestamp: 1
        )
        decorator = MessageDecorator.for(event)

        expect(decorator.render_verbose).to eq({
          role: :think, content: "Checking the logs now", visibility: "aloud", timestamp: 1
        })
      end

      it "defaults to inner visibility when not specified" do
        event = session.messages.create!(
          message_type: "tool_call",
          payload: {"content" => "thinking", "tool_name" => "think",
                    "tool_input" => {"thoughts" => "Planning"}},
          tool_use_id: "toolu_think_v3",
          timestamp: 1
        )
        decorator = MessageDecorator.for(event)

        expect(decorator.render_verbose).to eq({
          role: :think, content: "Planning", visibility: "inner", timestamp: 1
        })
      end
    end
  end

  describe "#render_debug" do
    it "returns full untruncated input in TOON format" do
      input = {"command" => "git status"}
      event = session.messages.create!(
        message_type: "tool_call",
        payload: {
          "content" => "running git status", "tool_name" => "bash",
          "tool_input" => input, "tool_use_id" => "toolu_01abc123"
        },
        timestamp: 1,
        tool_use_id: "toolu_01abc123"
      )
      decorator = MessageDecorator.for(event)

      expect(decorator.render_debug).to eq({
        role: :tool_call,
        tool: "bash",
        input: Toon.encode(input),
        tool_use_id: "toolu_01abc123",
        timestamp: 1
      })
    end

    it "includes tool_use_id from payload" do
      event = session.messages.create!(
        message_type: "tool_call",
        payload: {
          "content" => "calling", "tool_name" => "web_get",
          "tool_input" => {"url" => "https://example.com"}, "tool_use_id" => "toolu_xyz"
        },
        timestamp: 1,
        tool_use_id: "toolu_xyz"
      )
      decorator = MessageDecorator.for(event)
      result = decorator.render_debug

      expect(result[:tool_use_id]).to eq("toolu_xyz")
    end

    it "shows full input without truncation for complex payloads" do
      large_input = {"a" => "1", "b" => "2", "c" => "3", "d" => "4", "e" => "5"}
      event = session.messages.create!(
        message_type: "tool_call",
        payload: {
          "content" => "calling", "tool_name" => "custom",
          "tool_input" => large_input, "tool_use_id" => "toolu_big"
        },
        timestamp: 1,
        tool_use_id: "toolu_big"
      )
      decorator = MessageDecorator.for(event)
      result = decorator.render_debug

      expect(result[:input]).to eq(Toon.encode(large_input))
      expect(result[:input]).not_to include("...")
    end

    it "handles nil tool_input" do
      event = session.messages.create!(
        message_type: "tool_call",
        payload: {"content" => "calling", "tool_name" => "bash", "tool_input" => nil},
        tool_use_id: "toolu_debug_nil",
        timestamp: 1
      )
      decorator = MessageDecorator.for(event)
      result = decorator.render_debug

      expect(result[:input]).to eq(Toon.encode({}))
    end

    it "works with hash payloads" do
      decorator = MessageDecorator.for(
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
      expect(result[:input]).to eq(Toon.encode({"command" => "ls"}))
    end

    context "write_file tool" do
      it "preserves newlines in multi-line content" do
        input = {"file_path" => "/tmp/soul.md", "content" => "line1\nline2\nline3"}
        event = session.messages.create!(
          message_type: "tool_call",
          payload: {
            "content" => "writing", "tool_name" => "write_file",
            "tool_input" => input, "tool_use_id" => "toolu_write1"
          },
          timestamp: 1,
          tool_use_id: "toolu_write1"
        )
        decorator = MessageDecorator.for(event)
        result = decorator.render_debug

        expect(result[:input]).to eq("/tmp/soul.md\nline1\nline2\nline3")
      end

      it "falls back to TOON when content is empty" do
        input = {"file_path" => "/tmp/empty.txt", "content" => ""}
        event = session.messages.create!(
          message_type: "tool_call",
          payload: {
            "content" => "writing", "tool_name" => "write_file",
            "tool_input" => input, "tool_use_id" => "toolu_write2"
          },
          timestamp: 1,
          tool_use_id: "toolu_write2"
        )
        decorator = MessageDecorator.for(event)
        result = decorator.render_debug

        expect(result[:input]).to eq(Toon.encode(input))
      end
    end

    context "think tool" do
      it "returns think role with full metadata" do
        event = session.messages.create!(
          message_type: "tool_call",
          payload: {
            "content" => "thinking", "tool_name" => "think",
            "tool_input" => {"thoughts" => "Auth failures suggest config issue", "visibility" => "inner"},
            "tool_use_id" => "toolu_think_1"
          },
          timestamp: 1,
          tool_use_id: "toolu_think_1"
        )
        decorator = MessageDecorator.for(event)

        expect(decorator.render_debug).to eq({
          role: :think,
          content: "Auth failures suggest config issue",
          visibility: "inner",
          tool_use_id: "toolu_think_1",
          timestamp: 1
        })
      end

      it "includes aloud visibility in debug mode" do
        event = session.messages.create!(
          message_type: "tool_call",
          payload: {
            "content" => "thinking aloud", "tool_name" => "think",
            "tool_input" => {"thoughts" => "Narrating for user", "visibility" => "aloud"},
            "tool_use_id" => "toolu_think_2"
          },
          timestamp: 1,
          tool_use_id: "toolu_think_2"
        )
        decorator = MessageDecorator.for(event)

        expect(decorator.render_debug).to eq({
          role: :think,
          content: "Narrating for user",
          visibility: "aloud",
          tool_use_id: "toolu_think_2",
          timestamp: 1
        })
      end
    end
  end

  describe "#render_brain" do
    it "returns tool name with params for regular tool calls" do
      event = session.messages.create!(
        message_type: "tool_call",
        payload: {"content" => "calling bash", "tool_name" => "bash",
                  "tool_input" => {"command" => "ls -la"}},
        tool_use_id: "toolu_brain1",
        timestamp: 1
      )
      decorator = MessageDecorator.for(event)

      expect(decorator.render_brain).to eq('Tool call: bash({"command":"ls -la"})')
    end

    it "returns full think text for think tool calls" do
      event = session.messages.create!(
        message_type: "tool_call",
        payload: {"content" => "thinking", "tool_name" => "think",
                  "tool_input" => {"thoughts" => "OAuth config is wrong, not individual tests."}},
        tool_use_id: "toolu_brain2",
        timestamp: 1
      )
      decorator = MessageDecorator.for(event)

      expect(decorator.render_brain).to eq("Think: OAuth config is wrong, not individual tests.")
    end

    it "handles nil tool_input for regular tools" do
      event = session.messages.create!(
        message_type: "tool_call",
        payload: {"content" => "calling", "tool_name" => "bash", "tool_input" => nil},
        tool_use_id: "toolu_brain3",
        timestamp: 1
      )
      decorator = MessageDecorator.for(event)

      expect(decorator.render_brain).to eq("Tool call: bash({})")
    end
  end
end
