# frozen_string_literal: true

require "rails_helper"

RSpec.describe ToolCallDecorator, type: :decorator do
  subject(:decorator) { message.decorate }

  describe "#render_basic" do
    context "for a regular tool call" do
      let(:message) do
        build_stubbed(:message, :tool_call,
          payload: {"content" => "calling bash", "tool_name" => "bash", "tool_input" => {"command" => "ls"}})
      end

      it "returns nil (hidden in basic mode)" do
        expect(decorator.render_basic).to be_nil
      end
    end

    context "for a think tool with inner visibility (default)" do
      let(:message) do
        build_stubbed(:message, :tool_call,
          payload: {"content" => "thinking", "tool_name" => "think", "tool_input" => {"thoughts" => "Planning next step"}})
      end

      it "returns nil" do
        expect(decorator.render_basic).to be_nil
      end
    end

    context "for a think tool with explicit inner visibility" do
      let(:message) do
        build_stubbed(:message, :tool_call,
          payload: {"content" => "thinking", "tool_name" => "think",
                    "tool_input" => {"thoughts" => "Planning next step", "visibility" => "inner"}})
      end

      it "returns nil" do
        expect(decorator.render_basic).to be_nil
      end
    end

    context "for a think tool with aloud visibility" do
      let(:message) do
        build_stubbed(:message, :tool_call,
          payload: {"content" => "thinking aloud", "tool_name" => "think",
                    "tool_input" => {"thoughts" => "Checking the config first.", "visibility" => "aloud"}})
      end

      it "returns a structured hash" do
        expect(decorator.render_basic).to eq({
          role: :think, content: "Checking the config first.", visibility: "aloud"
        })
      end
    end
  end

  describe "#render_verbose" do
    context "with a bash command" do
      let(:message) do
        build_stubbed(:message, :tool_call,
          payload: {"content" => "running git status", "tool_name" => "bash", "tool_input" => {"command" => "git status"}},
          timestamp: 1)
      end

      it "renders the command with a shell prompt" do
        expect(decorator.render_verbose).to eq({
          role: :tool_call, tool: "bash", input: "$ git status", timestamp: 1
        })
      end
    end

    context "with a web_get URL" do
      let(:message) do
        build_stubbed(:message, :tool_call,
          payload: {"content" => "fetching", "tool_name" => "web_get", "tool_input" => {"url" => "https://example.com/api"}},
          timestamp: 1)
      end

      it "renders the URL with a GET prefix" do
        expect(decorator.render_verbose).to eq({
          role: :tool_call, tool: "web_get", input: "GET https://example.com/api", timestamp: 1
        })
      end
    end

    context "with a read_file tool" do
      let(:message) do
        build_stubbed(:message, :tool_call,
          payload: {"content" => "reading", "tool_name" => "read_file", "tool_input" => {"path" => "/app/models/user.rb"}},
          timestamp: 1)
      end

      it "returns the file path" do
        expect(decorator.render_verbose).to eq({
          role: :tool_call, tool: "read_file", input: "/app/models/user.rb", timestamp: 1
        })
      end
    end

    context "with an edit_file tool" do
      let(:message) do
        build_stubbed(:message, :tool_call,
          payload: {"content" => "editing", "tool_name" => "edit_file",
                    "tool_input" => {"path" => "/app/models/user.rb", "changes" => "..."}},
          timestamp: 1)
      end

      it "returns the file path" do
        expect(decorator.render_verbose).to eq({
          role: :tool_call, tool: "edit_file", input: "/app/models/user.rb", timestamp: 1
        })
      end
    end

    context "with a write_file tool" do
      let(:message) do
        build_stubbed(:message, :tool_call,
          payload: {"content" => "writing", "tool_name" => "write_file",
                    "tool_input" => {"path" => "/tmp/output.txt", "content" => "data"}},
          timestamp: 1)
      end

      it "returns the file path" do
        expect(decorator.render_verbose).to eq({
          role: :tool_call, tool: "write_file", input: "/tmp/output.txt", timestamp: 1
        })
      end
    end

    context "with an unknown tool" do
      let(:message) do
        build_stubbed(:message, :tool_call,
          payload: {"content" => "calling custom", "tool_name" => "custom_tool", "tool_input" => {"key" => "value"}},
          timestamp: 1)
      end

      it "returns TOON-encoded input" do
        expect(decorator.render_verbose).to eq({
          role: :tool_call, tool: "custom_tool", input: "key: value", timestamp: 1
        })
      end
    end

    context "with a multi-line generic tool_input" do
      let(:input) { {"a" => "1\n2\n3\n4\n5"} }
      let(:message) do
        build_stubbed(:message, :tool_call,
          payload: {"content" => "calling", "tool_name" => "custom", "tool_input" => input},
          timestamp: 1)
      end

      it "returns TOON-encoded input" do
        expect(decorator.render_verbose).to eq({
          role: :tool_call, tool: "custom", input: Toon.encode(input), timestamp: 1
        })
      end
    end

    context "with nil tool_input for bash" do
      let(:message) do
        build_stubbed(:message, :tool_call,
          payload: {"content" => "calling bash", "tool_name" => "bash", "tool_input" => nil},
          timestamp: 1)
      end

      it "renders an empty shell prompt" do
        expect(decorator.render_verbose).to eq({
          role: :tool_call, tool: "bash", input: "$ ", timestamp: 1
        })
      end
    end

    context "for a think tool with inner visibility" do
      let(:message) do
        build_stubbed(:message, :tool_call,
          payload: {"content" => "thinking", "tool_name" => "think",
                    "tool_input" => {"thoughts" => "I should check the logs", "visibility" => "inner"}},
          timestamp: 1)
      end

      it "returns a think role hash with inner visibility" do
        expect(decorator.render_verbose).to eq({
          role: :think, content: "I should check the logs", visibility: "inner", timestamp: 1
        })
      end
    end

    context "for a think tool with aloud visibility" do
      let(:message) do
        build_stubbed(:message, :tool_call,
          payload: {"content" => "thinking", "tool_name" => "think",
                    "tool_input" => {"thoughts" => "Checking the logs now", "visibility" => "aloud"}},
          timestamp: 1)
      end

      it "returns a think role hash with aloud visibility" do
        expect(decorator.render_verbose).to eq({
          role: :think, content: "Checking the logs now", visibility: "aloud", timestamp: 1
        })
      end
    end

    context "for a think tool without visibility field" do
      let(:message) do
        build_stubbed(:message, :tool_call,
          payload: {"content" => "thinking", "tool_name" => "think", "tool_input" => {"thoughts" => "Planning"}},
          timestamp: 1)
      end

      it "defaults to inner visibility" do
        expect(decorator.render_verbose).to eq({
          role: :think, content: "Planning", visibility: "inner", timestamp: 1
        })
      end
    end
  end

  describe "#render_debug" do
    context "with a bash command" do
      let(:input) { {"command" => "git status"} }
      let(:message) do
        build_stubbed(:message, :tool_call,
          payload: {"content" => "running git status", "tool_name" => "bash", "tool_input" => input, "tool_use_id" => "toolu_01abc123"},
          tool_use_id: "toolu_01abc123",
          timestamp: 1)
      end

      it "returns full untruncated input in TOON format" do
        expect(decorator.render_debug).to eq({
          role: :tool_call,
          tool: "bash",
          input: Toon.encode(input),
          tool_use_id: "toolu_01abc123",
          timestamp: 1
        })
      end
    end

    context "with a web_get tool" do
      let(:message) do
        build_stubbed(:message, :tool_call,
          payload: {"content" => "calling", "tool_name" => "web_get",
                    "tool_input" => {"url" => "https://example.com"}, "tool_use_id" => "toolu_xyz"},
          tool_use_id: "toolu_xyz",
          timestamp: 1)
      end

      it "includes the tool_use_id from payload" do
        expect(decorator.render_debug[:tool_use_id]).to eq("toolu_xyz")
      end
    end

    context "with a large custom tool input" do
      let(:large_input) { {"a" => "1", "b" => "2", "c" => "3", "d" => "4", "e" => "5"} }
      let(:message) do
        build_stubbed(:message, :tool_call,
          payload: {"content" => "calling", "tool_name" => "custom",
                    "tool_input" => large_input, "tool_use_id" => "toolu_big"},
          tool_use_id: "toolu_big",
          timestamp: 1)
      end

      it "shows full input without truncation" do
        result = decorator.render_debug
        expect(result[:input]).to eq(Toon.encode(large_input))
        expect(result[:input]).not_to include("...")
      end
    end

    context "with nil tool_input" do
      let(:message) do
        build_stubbed(:message, :tool_call,
          payload: {"content" => "calling", "tool_name" => "bash", "tool_input" => nil},
          tool_use_id: "toolu_debug_nil",
          timestamp: 1)
      end

      it "encodes an empty hash" do
        expect(decorator.render_debug[:input]).to eq(Toon.encode({}))
      end
    end

    context "for a write_file tool with multi-line content" do
      let(:input) { {"path" => "/tmp/soul.md", "content" => "line1\nline2\nline3"} }
      let(:message) do
        build_stubbed(:message, :tool_call,
          payload: {"content" => "writing", "tool_name" => "write_file",
                    "tool_input" => input, "tool_use_id" => "toolu_write1"},
          tool_use_id: "toolu_write1",
          timestamp: 1)
      end

      it "preserves the newlines" do
        expect(decorator.render_debug[:input]).to eq("/tmp/soul.md\nline1\nline2\nline3")
      end
    end

    context "for a write_file tool with empty content" do
      let(:input) { {"path" => "/tmp/empty.txt", "content" => ""} }
      let(:message) do
        build_stubbed(:message, :tool_call,
          payload: {"content" => "writing", "tool_name" => "write_file",
                    "tool_input" => input, "tool_use_id" => "toolu_write2"},
          tool_use_id: "toolu_write2",
          timestamp: 1)
      end

      it "falls back to TOON encoding" do
        expect(decorator.render_debug[:input]).to eq(Toon.encode(input))
      end
    end

    context "for a think tool with inner visibility" do
      let(:message) do
        build_stubbed(:message, :tool_call,
          payload: {"content" => "thinking", "tool_name" => "think",
                    "tool_input" => {"thoughts" => "Auth failures suggest config issue", "visibility" => "inner"},
                    "tool_use_id" => "toolu_think_1"},
          tool_use_id: "toolu_think_1",
          timestamp: 1)
      end

      it "returns a think role with full metadata" do
        expect(decorator.render_debug).to eq({
          role: :think,
          content: "Auth failures suggest config issue",
          visibility: "inner",
          tool_use_id: "toolu_think_1",
          timestamp: 1
        })
      end
    end

    context "for a think tool with aloud visibility" do
      let(:message) do
        build_stubbed(:message, :tool_call,
          payload: {"content" => "thinking aloud", "tool_name" => "think",
                    "tool_input" => {"thoughts" => "Narrating for user", "visibility" => "aloud"},
                    "tool_use_id" => "toolu_think_2"},
          tool_use_id: "toolu_think_2",
          timestamp: 1)
      end

      it "includes aloud visibility" do
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

  describe "#render_melete" do
    context "with a regular tool call" do
      let(:message) do
        build_stubbed(:message, :tool_call,
          payload: {"content" => "calling bash", "tool_name" => "bash", "tool_input" => {"command" => "ls -la"}})
      end

      it "returns the tool name with parameters" do
        expect(decorator.render_melete).to eq('Tool call: bash({"command":"ls -la"})')
      end
    end

    context "with a think tool call" do
      let(:message) do
        build_stubbed(:message, :tool_call,
          payload: {"content" => "thinking", "tool_name" => "think",
                    "tool_input" => {"thoughts" => "OAuth config is wrong, not individual tests."}})
      end

      it "returns the full think text" do
        expect(decorator.render_melete).to eq("Think: OAuth config is wrong, not individual tests.")
      end
    end

    context "with nil tool_input" do
      let(:message) do
        build_stubbed(:message, :tool_call,
          payload: {"content" => "calling", "tool_name" => "bash", "tool_input" => nil})
      end

      it "renders an empty hash for parameters" do
        expect(decorator.render_melete).to eq("Tool call: bash({})")
      end
    end
  end
end
